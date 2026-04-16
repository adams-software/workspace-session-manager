#ifndef MSR_VTERM_SHIM_H
#define MSR_VTERM_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <vterm.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct msr_vterm_hyperlink_record {
  char *params;
  size_t params_len;
  char *uri;
  size_t uri_len;
} msr_vterm_hyperlink_record;

typedef struct msr_vterm_history_event msr_vterm_history_event;

typedef struct {
  VTerm *vt;
  VTermState *state;
  VTermScreen *screen;
  int rows;
  int cols;
  int cursor_visible;
  int alt_screen;
  char *osc8_buf;
  size_t osc8_buf_len;
  size_t osc8_buf_cap;
  msr_vterm_hyperlink_record *hyperlinks;
  size_t hyperlinks_len;
  size_t hyperlinks_cap;
  int history_events_enabled;
  msr_vterm_history_event *history_events;
  size_t history_events_len;
  size_t history_events_cap;
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
  uint32_t hyperlink_handle;
  msr_vterm_color fg;
  msr_vterm_color bg;
  msr_vterm_cell_attrs attrs;
} msr_vterm_cell;

struct msr_vterm_history_event {
  uint8_t kind;
  uint8_t continuation;
  uint16_t rows;
  uint16_t cols;
  msr_vterm_cell *cells;
};

enum {
  MSR_VTERM_HISTORY_NONE = 0,
  MSR_VTERM_HISTORY_LINE_COMMITTED = 1,
  MSR_VTERM_HISTORY_ALT_ENTER = 2,
  MSR_VTERM_HISTORY_ALT_EXIT = 3,
  MSR_VTERM_HISTORY_RESIZE = 4,
};

msr_vterm_handle *msr_vterm_new(int rows, int cols, int grapheme_mode);
void msr_vterm_free(msr_vterm_handle *handle);
void msr_vterm_set_size(msr_vterm_handle *handle, int rows, int cols);
void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len);
void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible);
int msr_vterm_get_alt_screen(msr_vterm_handle *handle);
void msr_vterm_get_cell(msr_vterm_handle *handle, int row, int col, msr_vterm_cell *out);
int msr_vterm_row_is_eol(msr_vterm_handle *handle, int row);
const char *msr_vterm_get_hyperlink_uri(msr_vterm_handle *handle, uint32_t hyperlink_handle, size_t *len);
const char *msr_vterm_get_hyperlink_params(msr_vterm_handle *handle, uint32_t hyperlink_handle, size_t *len);
void msr_vterm_enable_history_events(msr_vterm_handle *handle, int enable);
int msr_vterm_next_history_event(msr_vterm_handle *handle, msr_vterm_history_event *out);

#ifdef __cplusplus
}
#endif

#endif
