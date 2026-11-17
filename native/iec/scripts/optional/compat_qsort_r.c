/* compat_qsort_r.c — qsort_r for OHOS libc.
 *
 * bionic/musl variants of OHOS libc do not expose qsort_r.  The tools we link
 * as IEC command objects (zstd's dictionary trainer) use the glibc argument
 * order.  A small single-threaded adapter is enough; nothing in the tools sorts
 * concurrently.
 */
#include <stdlib.h>

static int (*iec_qsort_cmp)(const void *, const void *, void *);
static void *iec_qsort_arg;

static int iec_qsort_thunk(const void *a, const void *b)
{
	return iec_qsort_cmp(a, b, iec_qsort_arg);
}

void qsort_r(void *base, size_t nmemb, size_t size,
	     int (*compar)(const void *, const void *, void *), void *arg)
{
	iec_qsort_cmp = compar;
	iec_qsort_arg = arg;
	qsort(base, nmemb, size, iec_qsort_thunk);
}
