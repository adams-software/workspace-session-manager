#include "vterm_shim.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum { MSR_MAX_OSC8_BYTES = 8192 };

static int ensure_osc8_buf(msr_vterm_handle *h, size_t additional) {
  size_t needed = h->osc8_buf_len + additional + 1;
  if (needed > MSR_MAX_OSC8_BYTES) return 0;
  if (needed <= h->osc8_buf_cap) return 1;

  size_t next_cap = h->osc8_buf_cap ? h->osc8_buf_cap : 64;
  while (next_cap < needed) next_cap *= 2;
  if (next_cap > MSR_MAX_OSC8_BYTES) next_cap = MSR_MAX_OSC8_BYTES;

  char *next = (char *)realloc(h->osc8_buf, next_cap);
  if (!next) return 0;

  h->osc8_buf = next;
  h->osc8_buf_cap = next_cap;
  return 1;
}

static void reset_osc8_buf(msr_vterm_handle *h) {
  if (!h) return;
  h->osc8_buf_len = 0;
  if (h->osc8_buf) h->osc8_buf[0] = '\0';
}

static char *dup_bytes(const char *src, size_t len) {
  char *copy = (char *)malloc(len + 1);
  if (!copy) return NULL;
  if (len > 0) memcpy(copy, src, len);
  copy[len] = '\0';
  return copy;
}

// Hyperlink records are currently interned for the lifetime of the adapter.
// This is acceptable for now, but a long-lived session with many unique URLs
// will grow the table until teardown.
static uint32_t intern_hyperlink(msr_vterm_handle *h, const char *params, size_t params_len, const char *uri, size_t uri_len) {
  if (!h || !uri || uri_len == 0) return 0;

  for (size_t i = 0; i < h->hyperlinks_len; i++) {
    if (h->hyperlinks[i].params_len == params_len && h->hyperlinks[i].uri_len == uri_len &&
        memcmp(h->hyperlinks[i].params, params, params_len) == 0 &&
        memcmp(h->hyperlinks[i].uri, uri, uri_len) == 0) {
      return (uint32_t)(i + 1);
    }
  }

  if (h->hyperlinks_len == h->hyperlinks_cap) {
    size_t next_cap = h->hyperlinks_cap ? h->hyperlinks_cap * 2 : 8;
    msr_vterm_hyperlink_record *next = (msr_vterm_hyperlink_record *)realloc(
        h->hyperlinks, next_cap * sizeof(msr_vterm_hyperlink_record));
    if (!next) return 0;
    h->hyperlinks = next;
    h->hyperlinks_cap = next_cap;
  }

  char *params_copy = dup_bytes(params, params_len);
  if (!params_copy) return 0;
  char *uri_copy = dup_bytes(uri, uri_len);
  if (!uri_copy) {
    free(params_copy);
    return 0;
  }

  h->hyperlinks[h->hyperlinks_len].params = params_copy;
  h->hyperlinks[h->hyperlinks_len].params_len = params_len;
  h->hyperlinks[h->hyperlinks_len].uri = uri_copy;
  h->hyperlinks[h->hyperlinks_len].uri_len = uri_len;
  h->hyperlinks_len += 1;
  return (uint32_t)h->hyperlinks_len;
}

static void apply_osc8(msr_vterm_handle *h) {
  if (!h || !h->osc8_buf) return;

  const char *body = h->osc8_buf;
  size_t len = h->osc8_buf_len;
  const char *sep = (const char *)memchr(body, ';', len);
  if (!sep) return;

  const char *params = body;
  size_t params_len = (size_t)(sep - body);
  const char *uri = sep + 1;
  size_t uri_len = len - params_len - 1;

  VTermValue value;
  if (uri_len == 0) {
    value.number = 0;
  } else {
    uint32_t handle = intern_hyperlink(h, params, params_len, uri, uri_len);
    if (handle == 0) return;
    value.number = (int)handle;
  }

  vterm_state_set_penattr(h->state, VTERM_ATTR_URI, VTERM_VALUETYPE_INT, &value);
}

static int on_damage(VTermRect rect, void *user) {
  (void)rect;
  (void)user;
  return 1;
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
  .movecursor = on_movecursor,
  .settermprop = on_settermprop,
  .resize = on_resize,
};

static int fallback_osc(int command, VTermStringFragment frag, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  if (!h) return 0;

  if (frag.initial) reset_osc8_buf(h);
  if (command != 8) return 0;

  if (!ensure_osc8_buf(h, frag.len)) {
    reset_osc8_buf(h);
    return 1;
  }

  memcpy(h->osc8_buf + h->osc8_buf_len, frag.str, frag.len);
  h->osc8_buf_len += frag.len;
  h->osc8_buf[h->osc8_buf_len] = '\0';

  if (frag.final) apply_osc8(h);
  return 1;
}

static VTermStateFallbacks state_fallbacks = {
  .osc = fallback_osc,
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
  h->state = vterm_obtain_state(h->vt);
  h->rows = rows;
  h->cols = cols;
  h->cursor_visible = 1;
  h->alt_screen = 0;

  vterm_screen_set_callbacks(h->screen, &screen_cbs, h);
  vterm_screen_set_unrecognised_fallbacks(h->screen, &state_fallbacks, h);
  vterm_screen_enable_altscreen(h->screen, 1);
  vterm_screen_reset(h->screen, 1);
  vterm_screen_flush_damage(h->screen);
  vterm_screen_set_damage_merge(h->screen, VTERM_DAMAGE_SCROLL);

  return h;
}

void msr_vterm_free(msr_vterm_handle *handle) {
  if (!handle) return;
  if (handle->vt) vterm_free(handle->vt);
  free(handle->osc8_buf);
  for (size_t i = 0; i < handle->hyperlinks_len; i++) {
    free(handle->hyperlinks[i].params);
    free(handle->hyperlinks[i].uri);
  }
  free(handle->hyperlinks);
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

void msr_vterm_get_cursor(msr_vterm_handle *handle, int *row, int *col, int *visible) {
  if (!handle || !handle->vt) {
    if (row) *row = 0;
    if (col) *col = 0;
    if (visible) *visible = 0;
    return;
  }
  VTermPos pos = {0, 0};
  vterm_state_get_cursorpos(handle->state, &pos);
  if (row) *row = pos.row;
  if (col) *col = pos.col;
  if (visible) *visible = handle->cursor_visible;
}

int msr_vterm_get_alt_screen(msr_vterm_handle *handle) {
  if (!handle) return 0;
  return handle->alt_screen;
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
  out->hyperlink_handle = cell.uri > 0 ? (uint32_t)cell.uri : 0;
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

const char *msr_vterm_get_hyperlink_uri(msr_vterm_handle *handle, uint32_t hyperlink_handle, size_t *len) {
  if (len) *len = 0;
  if (!handle || hyperlink_handle == 0) return NULL;
  size_t idx = (size_t)hyperlink_handle - 1;
  if (idx >= handle->hyperlinks_len) return NULL;
  if (len) *len = handle->hyperlinks[idx].uri_len;
  return handle->hyperlinks[idx].uri;
}

const char *msr_vterm_get_hyperlink_params(msr_vterm_handle *handle, uint32_t hyperlink_handle, size_t *len) {
  if (len) *len = 0;
  if (!handle || hyperlink_handle == 0) return NULL;
  size_t idx = (size_t)hyperlink_handle - 1;
  if (idx >= handle->hyperlinks_len) return NULL;
  if (len) *len = handle->hyperlinks[idx].params_len;
  return handle->hyperlinks[idx].params;
}
