#include "vterm_shim.h"
#include <stdlib.h>
#include <string.h>

static int on_damage(VTermRect rect, void *user) {
  (void)rect;
  (void)user;
  return 1;
}

static int on_moverect(VTermRect dest, VTermRect src, void *user) {
  (void)src;
  return on_damage(dest, user);
}

static int on_movecursor(VTermPos pos, VTermPos oldpos, int visible, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  (void)pos;
  (void)oldpos;
  if (!h) return 1;
  h->cursor_visible = visible;
  return 1;
}

static int on_settermprop(VTermProp prop, VTermValue *val, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  if (!h) return 1;
  if (prop == VTERM_PROP_CURSORVISIBLE) h->cursor_visible = val->boolean;
  if (prop == VTERM_PROP_ALTSCREEN) h->alt_screen = val->boolean;
  return 1;
}

static int on_resize(int rows, int cols, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  if (!h) return 1;
  h->rows = rows;
  h->cols = cols;
  return 1;
}

static VTermScreenCallbacks screen_cbs = {
  .damage = on_damage,
  .moverect = on_moverect,
  .movecursor = on_movecursor,
  .settermprop = on_settermprop,
  .resize = on_resize,
};

static msr_vterm_color convert_color(VTermColor color) {
  msr_vterm_color out = {0};
  out.is_default_fg = VTERM_COLOR_IS_DEFAULT_FG(&color) ? 1 : 0;
  out.is_default_bg = VTERM_COLOR_IS_DEFAULT_BG(&color) ? 1 : 0;

  if (VTERM_COLOR_IS_INDEXED(&color)) {
    out.type = 1;
    out.palette_index = color.indexed.idx;
    return out;
  }
  if (VTERM_COLOR_IS_RGB(&color)) {
    out.type = 2;
    out.red = color.rgb.red;
    out.green = color.rgb.green;
    out.blue = color.rgb.blue;
    return out;
  }
  return out;
}

msr_vterm_handle *msr_vterm_new(int rows, int cols) {
  msr_vterm_handle *h = (msr_vterm_handle *)calloc(1, sizeof(msr_vterm_handle));
  if (!h) return NULL;

  h->vt = vterm_new(rows, cols);
  if (!h->vt) {
    free(h);
    return NULL;
  }

  vterm_set_utf8(h->vt, 1);

  h->screen = vterm_obtain_screen(h->vt);
  h->rows = rows;
  h->cols = cols;
  h->cursor_visible = 1;
  h->alt_screen = 0;

  vterm_screen_set_callbacks(h->screen, &screen_cbs, h);
  vterm_screen_enable_altscreen(h->screen, 1);
  vterm_screen_reset(h->screen, 1);
  vterm_screen_flush_damage(h->screen);
  vterm_screen_set_damage_merge(h->screen, VTERM_DAMAGE_SCROLL);

  return h;
}

void msr_vterm_free(msr_vterm_handle *handle) {
  if (!handle) return;
  if (handle->vt) vterm_free(handle->vt);
  free(handle);
}

void msr_vterm_set_size(msr_vterm_handle *handle, int rows, int cols) {
  if (!handle || !handle->vt) return;
  vterm_set_size(handle->vt, rows, cols);
}

void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len) {
  if (!handle || !handle->vt) return;
  vterm_input_write(handle->vt, bytes, len);
}

void msr_vterm_get_size(msr_vterm_handle *handle, int *rows, int *cols) {
  if (!handle || !handle->vt) {
    if (rows) *rows = 0;
    if (cols) *cols = 0;
    return;
  }
  vterm_get_size(handle->vt, rows, cols);
}

void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible) {
  if (!handle || !handle->vt) {
    if (row) *row = 0;
    if (col) *col = 0;
    if (visible) *visible = 0;
    return;
  }
  VTermState *state = vterm_obtain_state(handle->vt);
  VTermPos pos = {0, 0};
  vterm_state_get_cursorpos(state, &pos);
  if (row) *row = pos.row;
  if (col) *col = pos.col;
  if (visible) *visible = handle->cursor_visible;
}

int msr_vterm_get_alt_screen(msr_vterm_handle *handle) {
  if (!handle) return 0;
  return handle->alt_screen;
}

size_t msr_vterm_get_rect_text(msr_vterm_handle *handle, int row, int start_col, int end_col, char *buf, size_t len) {
  if (!handle || !handle->screen || !buf || len == 0) return 0;
  VTermRect rect = { .start_row = row, .end_row = row + 1, .start_col = start_col, .end_col = end_col };
  return vterm_screen_get_text(handle->screen, buf, len, rect);
}

void msr_vterm_force_full_damage(msr_vterm_handle *handle) {
  (void)handle;
}

void msr_vterm_get_cell(msr_vterm_handle *handle, int row, int col, msr_vterm_cell *out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));
  out->width = 1;

  if (!handle || !handle->screen) return;

  VTermScreenCell cell;
  VTermPos pos = { row, col };
  if (!vterm_screen_get_cell(handle->screen, pos, &cell)) return;

  size_t n = 0;
  while (n < VTERM_MAX_CHARS_PER_CELL && cell.chars[n]) {
    out->chars[n] = cell.chars[n];
    n++;
  }
  out->chars_len = (uint8_t)n;
  out->width = (uint8_t)cell.width;
  out->fg = convert_color(cell.fg);
  out->bg = convert_color(cell.bg);

  out->attrs.bold = cell.attrs.bold ? 1 : 0;
  out->attrs.italic = cell.attrs.italic ? 1 : 0;
  out->attrs.underline = cell.attrs.underline ? 1 : 0;
  out->attrs.blink = cell.attrs.blink ? 1 : 0;
  out->attrs.reverse = cell.attrs.reverse ? 1 : 0;
  out->attrs.conceal = cell.attrs.conceal ? 1 : 0;
  out->attrs.strike = cell.attrs.strike ? 1 : 0;
  out->attrs.font = cell.attrs.font;
}

int msr_vterm_row_is_eol(msr_vterm_handle *handle, int row) {
  if (!handle || !handle->screen) return 0;
  if (row < 0 || row >= handle->rows) return 0;
  VTermPos pos = { row, handle->cols > 0 ? handle->cols - 1 : 0 };
  return vterm_screen_is_eol(handle->screen, pos);
}
