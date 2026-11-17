/* compat_strverscmp.c — natural version comparison for tree's --sort=version.
 *
 * OHOS libc does not expose GNU strverscmp.  This is a small ASCII natural
 * comparison: digit runs are compared numerically, everything else bytewise.
 */
#include <ctype.h>

int strverscmp(const char *a, const char *b)
{
	const unsigned char *x = (const unsigned char *)a;
	const unsigned char *y = (const unsigned char *)b;

	while (*x && *y) {
		if (isdigit(*x) && isdigit(*y)) {
			unsigned long nx = 0, ny = 0;
			while (isdigit(*x)) nx = nx * 10 + (unsigned long)(*x++ - '0');
			while (isdigit(*y)) ny = ny * 10 + (unsigned long)(*y++ - '0');
			if (nx != ny) return nx < ny ? -1 : 1;
			continue;
		}
		if (*x != *y) return *x < *y ? -1 : 1;
		x++;
		y++;
	}
	if (*x == *y) return 0;
	return *x ? 1 : -1;
}
