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
  int rows;
  int cols;
  int cursor_visible;
  int alt_screen;
  uint8_t *dirty_rows;
  int full_damage;
} msr_vterm_handle;

typedef struct {
  uint8_t type;
  uint8_t palette_index;
  uint8_t red;
  uint8_t green;
  uint8_t blue;
  uint8_t is_default_fg;
  uint8_t is_default_bg;
} msr_vterm_color;

typedef struct {
  uint8_t bold;
  uint8_t underline;
  uint8_t inverse;
  uint8_t font;
  msr_vterm_color fg;
  msr_vterm_color bg;
} msr_vterm_cell_style;

typedef struct {
  uint8_t bold;
  uint8_t italic;
  uint8_t underline;
  uint8_t blink;
  uint8_t reverse;
  uint8_t conceal;
  uint8_t strike;
  uint8_t font;
} msr_vterm_cell_attrs;

typedef struct {
  uint32_t chars[VTERM_MAX_CHARS_PER_CELL];
  uint8_t chars_len;
  uint8_t width;
  msr_vterm_color fg;
  msr_vterm_color bg;
  msr_vterm_cell_attrs attrs;
} msr_vterm_cell;

msr_vterm_handle *msr_vterm_new(int rows, int cols);
void msr_vterm_free(msr_vterm_handle *handle);
void msr_vterm_set_size(msr_vterm_handle *handle, int rows, int cols);
void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len);
void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible);
int msr_vterm_get_alt_screen(msr_vterm_handle *handle);
void msr_vterm_force_full_damage(msr_vterm_handle *handle);
void msr_vterm_flush_damage(msr_vterm_handle *handle);
void msr_vterm_get_cell(msr_vterm_handle *handle, int row, int col, msr_vterm_cell *out);
int msr_vterm_row_is_eol(msr_vterm_handle *handle, int row);


#ifdef __cplusplus
}
#endif

#endif
