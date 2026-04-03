#ifndef MSR_VTERM_SHIM_H
#define MSR_VTERM_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <vterm.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  VTerm *vt;
  VTermScreen *screen;
} msr_vterm_handle;

msr_vterm_handle *msr_vterm_new(int rows, int cols);
void msr_vterm_free(msr_vterm_handle *handle);
void msr_vterm_set_size(msr_vterm_handle *handle, int rows, int cols);
void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len);
void msr_vterm_get_size(msr_vterm_handle *handle, int *rows, int *cols);
void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible);
int msr_vterm_get_alt_screen(msr_vterm_handle *handle);
uint32_t msr_vterm_get_cell_codepoint(msr_vterm_handle *handle, int row, int col);

#ifdef __cplusplus
}
#endif

#endif
