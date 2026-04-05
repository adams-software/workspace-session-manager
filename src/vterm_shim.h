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

typedef struct {
  uint8_t type;
  uint8_t palette_index;
  uint8_t red;
  uint8_t green;
  uint8_t blue;
} msr_vterm_color;

typedef struct {
  uint8_t bold;
  uint8_t underline;
  uint8_t inverse;
  msr_vterm_color fg;
  msr_vterm_color bg;
} msr_vterm_cell_style;

msr_vterm_handle *msr_vterm_new(int rows, int cols);
void msr_vterm_free(msr_vterm_handle *handle);
void msr_vterm_set_size(msr_vterm_handle *handle, int rows, int cols);
void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len);
void msr_vterm_get_size(msr_vterm_handle *handle, int *rows, int *cols);
void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible);
int msr_vterm_get_alt_screen(msr_vterm_handle *handle);
uint32_t msr_vterm_get_cell_codepoint(msr_vterm_handle *handle, int row, int col);
void msr_vterm_get_cell_style(msr_vterm_handle *handle, int row, int col, msr_vterm_cell_style *out);

#ifdef __cplusplus
}
#endif

#endif
