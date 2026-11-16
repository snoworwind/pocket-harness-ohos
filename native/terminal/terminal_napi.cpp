// terminal_napi.cpp — libvterm 原生终端内核的 NAPI 入口。
//
// 与 pocket-harness 的 terminal_jni.c 保持同一套交付约定：
//   - 屏幕以定长 cell 缓冲交付，每 cell 16 字节（chars u32 / fg u32 / bg u32 /
//     attrs u8 / width u8 / pad u16）；
//   - 颜色是 0xRRGGBB，0xFFFFFFFF 表示默认色（由 ArkTS 侧映射主题）；
//   - 句柄 0 表示创建失败；所有调用必须在同一线程（当前是 UI 线程）。
#include <napi/native_api.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <vterm.h>

#define DSH_CELL_BYTES 16
#define DSH_SCROLLBACK_MAX 2000

typedef struct {
    unsigned char* cells;
    int cols;
} DshScrollbackLine;

typedef struct {
    VTerm* vt;
    VTermScreen* screen;
    int rows;
    int cols;
    int cursor_row;
    int cursor_col;
    int cursor_visible;
    DshScrollbackLine sb[DSH_SCROLLBACK_MAX];
    int sb_head;
    int sb_count;
} DshTerminal;

static void DshScrollbackClear(DshTerminal* term) {
    for (int i = 0; i < DSH_SCROLLBACK_MAX; i++) {
        free(term->sb[i].cells);
        term->sb[i].cells = NULL;
    }
    term->sb_head = 0;
    term->sb_count = 0;
}

static int DshMoveCursor(VTermPos pos, VTermPos old_pos, int visible, void* user) {
    (void)old_pos;
    DshTerminal* term = (DshTerminal*)user;
    term->cursor_row = pos.row;
    term->cursor_col = pos.col;
    term->cursor_visible = visible;
    return 0;
}

static uint32_t DshColorRgb(VTermScreen* screen, VTermColor* color, int background) {
    if (background ? VTERM_COLOR_IS_DEFAULT_BG(color) : VTERM_COLOR_IS_DEFAULT_FG(color)) {
        return 0xFFFFFFFFu;
    }
    vterm_screen_convert_color_to_rgb(screen, color);
    if (VTERM_COLOR_IS_RGB(color)) {
        return ((uint32_t)color->rgb.red << 16) | ((uint32_t)color->rgb.green << 8) |
               (uint32_t)color->rgb.blue;
    }
    return 0xFFFFFFFFu;
}

static void DshWriteCell(unsigned char* out, const VTermScreenCell* cell, uint32_t fg, uint32_t bg) {
    uint32_t chars = cell->chars[0];
    unsigned char attrs = 0;
    if (cell->attrs.bold) attrs |= 1u;
    if (cell->attrs.underline) attrs |= 2u;
    if (cell->attrs.italic) attrs |= 4u;
    if (cell->attrs.reverse) attrs |= 8u;
    if (cell->attrs.blink) attrs |= 16u;
    if (cell->attrs.strike) attrs |= 32u;
    memcpy(out + 0, &chars, 4);
    memcpy(out + 4, &fg, 4);
    memcpy(out + 8, &bg, 4);
    out[12] = attrs;
    out[13] = (unsigned char)(cell->width > 0 ? cell->width : 1);
    out[14] = 0;
    out[15] = 0;
}

static int DshSbPushline(int cols, const VTermScreenCell* cells, void* user) {
    DshTerminal* term = (DshTerminal*)user;
    if (term == NULL || cols <= 0) return 0;
    unsigned char* line = (unsigned char*)malloc((size_t)cols * DSH_CELL_BYTES);
    if (line == NULL) return 0;
    for (int col = 0; col < cols; col++) {
        VTermScreenCell cell = cells[col];
        uint32_t fg = DshColorRgb(term->screen, &cell.fg, 0);
        uint32_t bg = DshColorRgb(term->screen, &cell.bg, 1);
        DshWriteCell(line + (size_t)col * DSH_CELL_BYTES, &cell, fg, bg);
    }
    if (term->sb_count == DSH_SCROLLBACK_MAX) {
        free(term->sb[term->sb_head].cells);
        term->sb[term->sb_head].cells = NULL;
        term->sb_head = (term->sb_head + 1) % DSH_SCROLLBACK_MAX;
        term->sb_count -= 1;
    }
    int slot = (term->sb_head + term->sb_count) % DSH_SCROLLBACK_MAX;
    term->sb[slot].cells = line;
    term->sb[slot].cols = cols;
    term->sb_count += 1;
    return 1;
}

static DshTerminal* DshFrom(napi_env env, napi_value value) {
    double handle = 0;
    if (napi_get_value_double(env, value, &handle) != napi_ok) return NULL;
    return (DshTerminal*)(intptr_t)handle;
}

static napi_value MakeInt(napi_env env, int value) {
    napi_value out = NULL;
    napi_create_int32(env, value, &out);
    return out;
}

// 句柄是 64 位指针：必须用 double 返回（JS number 能精确表示 53 位），
// 用 int32 会截断指针，回到 ArkTS 再当指针用就是野地址。
static napi_value MakeHandle(napi_env env, void* pointer) {
    napi_value out = NULL;
    napi_create_double(env, (double)(uintptr_t)pointer, &out);
    return out;
}

static napi_value Create(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {NULL, NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    int32_t cols = 0;
    int32_t rows = 0;
    if (argc < 2 || napi_get_value_int32(env, argv[0], &cols) != napi_ok ||
        napi_get_value_int32(env, argv[1], &rows) != napi_ok) {
        return MakeInt(env, 0);
    }
    if (cols < 2 || rows < 1) return MakeInt(env, 0);
    DshTerminal* term = (DshTerminal*)calloc(1, sizeof(DshTerminal));
    if (term == NULL) return MakeInt(env, 0);
    term->vt = vterm_new(rows, cols);
    if (term->vt == NULL) {
        free(term);
        return MakeInt(env, 0);
    }
    term->rows = rows;
    term->cols = cols;
    vterm_set_utf8(term->vt, 1);
    term->screen = vterm_obtain_screen(term->vt);
    static VTermScreenCallbacks callbacks;
    callbacks.movecursor = DshMoveCursor;
    callbacks.sb_pushline = DshSbPushline;
    if (term->screen == NULL) {
        vterm_free(term->vt);
        free(term);
        return MakeInt(env, 0);
    }
    vterm_screen_set_callbacks(term->screen, &callbacks, term);
    vterm_screen_enable_altscreen(term->screen, 1);
    vterm_screen_reset(term->screen, 1);
    vterm_screen_flush_damage(term->screen);
    return MakeHandle(env, term);
}

static napi_value Destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    DshTerminal* term = argc > 0 ? DshFrom(env, argv[0]) : NULL;
    napi_value out = NULL;
    napi_get_undefined(env, &out);
    if (term == NULL) return out;
    DshScrollbackClear(term);
    if (term->vt != NULL) vterm_free(term->vt);
    free(term);
    return out;
}

// input(handle, Uint8Array)
static napi_value Input(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {NULL, NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    napi_value out = NULL;
    napi_get_undefined(env, &out);
    if (argc < 2) return out;
    DshTerminal* term = DshFrom(env, argv[0]);
    if (term == NULL) return out;

    bool isTyped = false;
    napi_is_typedarray(env, argv[1], &isTyped);
    unsigned char* data = NULL;
    size_t length = 0;
    napi_typedarray_type type;
    if (isTyped) {
        napi_value buffer = NULL;
        size_t offset = 0;
        void* raw = NULL;
        if (napi_get_typedarray_info(env, argv[1], &type, &length, &raw, &buffer, &offset) != napi_ok ||
            raw == NULL) {
            return out;
        }
        data = (unsigned char*)raw;
    } else {
        void* raw = NULL;
        if (napi_get_arraybuffer_info(env, argv[1], &raw, &length) != napi_ok || raw == NULL) {
            return out;
        }
        data = (unsigned char*)raw;
    }
    if (data != NULL && length > 0) {
        vterm_input_write(term->vt, (const char*)data, length);
        vterm_screen_flush_damage(term->screen);
    }
    return out;
}

static napi_value Resize(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {NULL, NULL, NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    napi_value out = NULL;
    napi_get_undefined(env, &out);
    if (argc < 3) return out;
    DshTerminal* term = DshFrom(env, argv[0]);
    if (term == NULL) return out;
    int32_t cols = 0;
    int32_t rows = 0;
    if (napi_get_value_int32(env, argv[1], &cols) != napi_ok ||
        napi_get_value_int32(env, argv[2], &rows) != napi_ok) {
        return out;
    }
    if (cols < 2 || rows < 1) return out;
    vterm_set_size(term->vt, rows, cols);
    term->rows = rows;
    term->cols = cols;
    vterm_screen_flush_damage(term->screen);
    return out;
}

static napi_value CopyScreen(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2] = {NULL, NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 2) return MakeInt(env, -1);
    DshTerminal* term = DshFrom(env, argv[0]);
    if (term == NULL) return MakeInt(env, -1);
    void* raw = NULL;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, argv[1], &raw, &length) != napi_ok || raw == NULL) {
        return MakeInt(env, -1);
    }
    int cells = term->rows * term->cols;
    if (length < (size_t)cells * DSH_CELL_BYTES) return MakeInt(env, -1);
    unsigned char* out = (unsigned char*)raw;
    for (int row = 0; row < term->rows; row++) {
        for (int col = 0; col < term->cols; col++) {
            VTermPos pos;
            pos.row = row;
            pos.col = col;
            VTermScreenCell cell;
            memset(&cell, 0, sizeof(cell));
            vterm_screen_get_cell(term->screen, pos, &cell);
            uint32_t fg = DshColorRgb(term->screen, &cell.fg, 0);
            uint32_t bg = DshColorRgb(term->screen, &cell.bg, 1);
            DshWriteCell(out + ((size_t)row * term->cols + col) * DSH_CELL_BYTES, &cell, fg, bg);
        }
    }
    return MakeInt(env, cells);
}

static napi_value ScrollbackCount(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    DshTerminal* term = argc > 0 ? DshFrom(env, argv[0]) : NULL;
    return MakeInt(env, term == NULL ? 0 : term->sb_count);
}

static napi_value CopyScrollback(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3] = {NULL, NULL, NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (argc < 3) return MakeInt(env, -1);
    DshTerminal* term = DshFrom(env, argv[0]);
    if (term == NULL) return MakeInt(env, -1);
    int32_t index = 0;
    if (napi_get_value_int32(env, argv[1], &index) != napi_ok) return MakeInt(env, -1);
    if (index < 0 || index >= term->sb_count) return MakeInt(env, -1);
    int slot = (term->sb_head + index) % DSH_SCROLLBACK_MAX;
    const unsigned char* cells = term->sb[slot].cells;
    if (cells == NULL) return MakeInt(env, -1);
    void* raw = NULL;
    size_t length = 0;
    if (napi_get_arraybuffer_info(env, argv[2], &raw, &length) != napi_ok || raw == NULL) {
        return MakeInt(env, -1);
    }
    if (length < (size_t)term->cols * DSH_CELL_BYTES) return MakeInt(env, -1);
    memset(raw, 0, (size_t)term->cols * DSH_CELL_BYTES);
    for (int col = 0; col < term->cols; ++col) {
        uint32_t defaults[2] = {0xFFFFFFFFu, 0xFFFFFFFFu};
        memcpy((unsigned char*)raw + col * DSH_CELL_BYTES + 4, defaults, sizeof defaults);
    }
    const int count = term->sb[slot].cols < term->cols ? term->sb[slot].cols : term->cols;
    memcpy(raw, cells, (size_t)count * DSH_CELL_BYTES);
    return MakeInt(env, term->cols);
}

static napi_value Cursor(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {NULL};
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    DshTerminal* term = argc > 0 ? DshFrom(env, argv[0]) : NULL;
    if (term == NULL) return MakeInt(env, 0);
    int value = (term->cursor_visible ? 1 : 0) | ((term->cursor_col & 0x7FFF) << 1) |
                ((term->cursor_row & 0xFFFF) << 16);
    return MakeInt(env, value);
}

static napi_value ReadOutput(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1] = {NULL}, result = NULL;
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    DshTerminal* term = argc ? DshFrom(env, argv[0]) : NULL;
    char buffer[4096];
    size_t size = term ? vterm_output_read(term->vt, buffer, sizeof buffer) : 0;
    napi_create_string_utf8(env, buffer, size, &result);
    return result;
}

static napi_value CellBytes(napi_env env, napi_callback_info info) {
    (void)info;
    return MakeInt(env, DSH_CELL_BYTES);
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"create", NULL, Create, NULL, NULL, NULL, napi_default, NULL},
        {"destroy", NULL, Destroy, NULL, NULL, NULL, napi_default, NULL},
        {"input", NULL, Input, NULL, NULL, NULL, napi_default, NULL},
        {"resize", NULL, Resize, NULL, NULL, NULL, napi_default, NULL},
        {"copyScreen", NULL, CopyScreen, NULL, NULL, NULL, napi_default, NULL},
        {"scrollbackCount", NULL, ScrollbackCount, NULL, NULL, NULL, napi_default, NULL},
        {"copyScrollback", NULL, CopyScrollback, NULL, NULL, NULL, napi_default, NULL},
        {"cursor", NULL, Cursor, NULL, NULL, NULL, napi_default, NULL},
        {"cellBytes", NULL, CellBytes, NULL, NULL, NULL, napi_default, NULL},
        {"readOutput", NULL, ReadOutput, NULL, NULL, NULL, napi_default, NULL},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module g_terminal_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = NULL,
    .nm_register_func = Init,
    .nm_modname = "dsh_terminal",
    .nm_priv = NULL,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterDshTerminalModule(void) {
    napi_module_register(&g_terminal_module);
}
