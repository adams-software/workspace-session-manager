#include "vterm_shim.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum { MSR_MAX_OSC8_BYTES = 8192 };

static int ensure_history_event_cap(msr_vterm_handle *h, size_t additional) {
  // Reclaim dequeued slots once when appending, rather than on every pop.
  if (h->history_events_head) {
    memmove(h->history_events, h->history_events + h->history_events_head,
            h->history_events_len * sizeof(msr_vterm_history_event));
    h->history_events_head = 0;
  }
  size_t needed = h->history_events_len + additional;
  if (needed <= h->history_events_cap) return 1;
  size_t next_cap = h->history_events_cap ? h->history_events_cap * 2 : 16;
  while (next_cap < needed) next_cap *= 2;
  msr_vterm_history_event *next = (msr_vterm_history_event *)realloc(h->history_events, next_cap * sizeof(msr_vterm_history_event));
  if (!next) return 0;
  h->history_events = next;
  h->history_events_cap = next_cap;
  return 1;
}

static int push_history_event(msr_vterm_handle *h, msr_vterm_history_event ev) {
  if (!h || !h->history_events_enabled) return 1;
  if (!ensure_history_event_cap(h, 1)) return 0;
  h->history_events[h->history_events_len++] = ev;
  return 1;
}

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

static msr_vterm_color convert_color(VTermColor color, uint8_t ansi_class, uint8_t promoted_by_bold) {
  msr_vterm_color out = {0};
  out.is_default_fg = VTERM_COLOR_IS_DEFAULT_FG(&color) ? 1 : 0;
  out.is_default_bg = VTERM_COLOR_IS_DEFAULT_BG(&color) ? 1 : 0;
  out.ansi_class = ansi_class;
  out.promoted_by_bold = promoted_by_bold;

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

// Bounded, generation-checked metadata cache. Expired cells lose their link,
// never acquire another cell's URL. Snapshot metadata owns separate copies.
static uint32_t hyperlink_hash(const char *params, size_t params_len, const char *uri, size_t uri_len) {
  uint32_t hash = 2166136261u;
  for (size_t i = 0; i < params_len; i++) hash = (hash ^ (unsigned char)params[i]) * 16777619u;
  hash = (hash ^ 0xffu) * 16777619u;
  for (size_t i = 0; i < uri_len; i++) hash = (hash ^ (unsigned char)uri[i]) * 16777619u;
  return hash;
}

static msr_vterm_hyperlink_record *find_hyperlink(msr_vterm_handle *h, uint32_t id) {
  if (!h || !h->hyperlinks || !id) return NULL;
  msr_vterm_hyperlink_record *link = &h->hyperlinks[(id - 1) % MSR_HYPERLINK_SLOTS];
  return link->id == id ? link : NULL;
}

static void evict_hyperlink(msr_vterm_handle *h, uint32_t id) {
  msr_vterm_hyperlink_record *link = find_hyperlink(h, id);
  if (!link) return;
  uint32_t *entry = &h->hyperlink_buckets[link->hash % MSR_HYPERLINK_BUCKETS];
  while (*entry && *entry != id) {
    msr_vterm_hyperlink_record *prev = find_hyperlink(h, *entry);
    if (!prev) break;
    entry = &prev->next;
  }
  if (*entry == id) *entry = link->next;
  h->hyperlink_bytes -= link->params_len + link->uri_len + 2;
  free(link->params);
  free(link->uri);
  memset(link, 0, sizeof(*link));
}

static uint32_t intern_hyperlink(msr_vterm_handle *h, const char *params, size_t params_len, const char *uri, size_t uri_len) {
  if (!h || !uri || uri_len == 0) return 0;
  if (params_len > MSR_HYPERLINK_BYTES - 2 || uri_len > MSR_HYPERLINK_BYTES - 2 - params_len) return 0;
  uint32_t hash = hyperlink_hash(params, params_len, uri, uri_len);
  size_t bucket = hash % MSR_HYPERLINK_BUCKETS;
  for (uint32_t id = h->hyperlink_buckets[bucket]; id;) {
    msr_vterm_hyperlink_record *link = find_hyperlink(h, id);
    if (!link) break;
    if (link->hash == hash && link->params_len == params_len && link->uri_len == uri_len &&
        memcmp(link->params, params, params_len) == 0 && memcmp(link->uri, uri, uri_len) == 0) return id;
    id = link->next;
  }

  // libvterm stores URI handles in a signed int. Never wrap/reuse an ID.
  if (h->next_hyperlink_id >= INT32_MAX) return 0;
  if (!h->hyperlinks) {
    h->hyperlinks = calloc(MSR_HYPERLINK_SLOTS, sizeof(*h->hyperlinks));
    if (!h->hyperlinks) return 0;
    h->hyperlinks_len = h->hyperlinks_cap = MSR_HYPERLINK_SLOTS;
    h->oldest_hyperlink_id = 1;
  }
  char *params_copy = dup_bytes(params, params_len);
  if (!params_copy) return 0;
  char *uri_copy = dup_bytes(uri, uri_len);
  if (!uri_copy) { free(params_copy); return 0; }

  uint32_t id = ++h->next_hyperlink_id;
  while (h->oldest_hyperlink_id < id &&
         (id - h->oldest_hyperlink_id >= MSR_HYPERLINK_SLOTS ||
          h->hyperlink_bytes + params_len + uri_len + 2 > MSR_HYPERLINK_BYTES)) {
    evict_hyperlink(h, h->oldest_hyperlink_id++);
  }
  msr_vterm_hyperlink_record *link = &h->hyperlinks[(id - 1) % MSR_HYPERLINK_SLOTS];
  *link = (msr_vterm_hyperlink_record){
    .id = id, .next = h->hyperlink_buckets[bucket], .hash = hash,
    .params = params_copy, .params_len = params_len, .uri = uri_copy, .uri_len = uri_len,
  };
  h->hyperlink_buckets[bucket] = id;
  h->hyperlink_bytes += params_len + uri_len + 2;
  return id;
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
  if (prop == VTERM_PROP_ALTSCREEN) {
    int new_alt = val->boolean;
    if (h->alt_screen != new_alt) {
      msr_vterm_history_event ev = {0};
      ev.kind = new_alt ? MSR_VTERM_HISTORY_ALT_ENTER : MSR_VTERM_HISTORY_ALT_EXIT;
      push_history_event(h, ev);
    }
    h->alt_screen = new_alt;
  }
  return 1;
}

static int on_resize(int rows, int cols, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  if (!h) return 1;
  h->rows = rows;
  h->cols = cols;
  msr_vterm_history_event ev = {0};
  ev.kind = MSR_VTERM_HISTORY_RESIZE;
  ev.rows = (uint16_t)rows;
  ev.cols = (uint16_t)cols;
  push_history_event(h, ev);
  return 1;
}

static int on_sb_pushline4(int cols, const VTermScreenCell *cells, bool continuation, void *user) {
  msr_vterm_handle *h = (msr_vterm_handle *)user;
  if (!h || !h->history_events_enabled) return 1;

  msr_vterm_cell *copy = (msr_vterm_cell *)calloc((size_t)cols, sizeof(msr_vterm_cell));
  if (!copy) return 0;

  for (int i = 0; i < cols; i++) {
    const VTermScreenCell *src = &cells[i];
    msr_vterm_cell *dst = &copy[i];
    size_t n = 0;
    while (n < VTERM_MAX_CHARS_PER_CELL && src->chars[n]) {
      dst->chars[n] = src->chars[n];
      n++;
    }
    dst->chars_len = (uint8_t)n;
    dst->width = (uint8_t)src->width;
    dst->hyperlink_handle = src->uri > 0 ? (uint32_t)src->uri : 0;
    dst->fg = convert_color(src->fg, 0, 0);
    dst->bg = convert_color(src->bg, 0, 0);
    dst->attrs.bold = src->attrs.bold ? 1 : 0;
    dst->attrs.italic = src->attrs.italic ? 1 : 0;
    dst->attrs.underline = src->attrs.underline ? 1 : 0;
    dst->attrs.blink = src->attrs.blink ? 1 : 0;
    dst->attrs.reverse = src->attrs.reverse ? 1 : 0;
    dst->attrs.conceal = src->attrs.conceal ? 1 : 0;
    dst->attrs.strike = src->attrs.strike ? 1 : 0;
    dst->attrs.font = src->attrs.font;
  }

  msr_vterm_history_event ev = {0};
  ev.kind = MSR_VTERM_HISTORY_LINE_COMMITTED;
  ev.continuation = continuation ? 1 : 0;
  ev.cols = (uint16_t)cols;
  ev.cells = copy;
  if (!push_history_event(h, ev)) {
    free(copy);
    return 0;
  }
  return 1;
}

static VTermScreenCallbacks screen_cbs = {
  .damage = on_damage,
  .movecursor = on_movecursor,
  .settermprop = on_settermprop,
  .resize = on_resize,
  .sb_pushline4 = on_sb_pushline4,
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

msr_vterm_handle *msr_vterm_new(int rows, int cols, int grapheme_mode) {
  msr_vterm_handle *h = (msr_vterm_handle *)calloc(1, sizeof(msr_vterm_handle));
  if (!h) return NULL;

  h->vt = vterm_new(rows, cols);
  if (!h->vt) {
    free(h);
    return NULL;
  }

  vterm_set_utf8(h->vt, 1);
  vterm_set_grapheme_mode(h->vt, grapheme_mode ? VTERM_GRAPHEME_MODE_UNICODE : VTERM_GRAPHEME_MODE_LEGACY);

  h->screen = vterm_obtain_screen(h->vt);
  h->state = vterm_obtain_state(h->vt);
  h->rows = rows;
  h->cols = cols;
  h->cursor_visible = 1;
  h->alt_screen = 0;

  vterm_screen_set_callbacks(h->screen, &screen_cbs, h);
  vterm_screen_callbacks_has_pushline4(h->screen);
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
  for (size_t i = 0; i < handle->history_events_len; i++) {
    free(handle->history_events[handle->history_events_head + i].cells);
  }
  free(handle->history_events);
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
  out->fg = convert_color(cell.fg, cell.fg_ansi_class, cell.fg_promoted_by_bold);
  out->bg = convert_color(cell.bg, cell.bg_ansi_class, cell.bg_promoted_by_bold);
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

const char *msr_vterm_get_hyperlink_uri(msr_vterm_handle *handle, uint32_t id, size_t *len) {
  if (len) *len = 0;
  msr_vterm_hyperlink_record *link = find_hyperlink(handle, id);
  if (!link) return NULL;
  if (len) *len = link->uri_len;
  return link->uri;
}

const char *msr_vterm_get_hyperlink_params(msr_vterm_handle *handle, uint32_t id, size_t *len) {
  if (len) *len = 0;
  msr_vterm_hyperlink_record *link = find_hyperlink(handle, id);
  if (!link) return NULL;
  if (len) *len = link->params_len;
  return link->params;
}

void msr_vterm_enable_history_events(msr_vterm_handle *handle, int enable) {
  if (!handle) return;
  handle->history_events_enabled = enable ? 1 : 0;
}

int msr_vterm_next_history_event(msr_vterm_handle *handle, msr_vterm_history_event *out) {
  if (!handle || !out || handle->history_events_len == 0) return 0;
  *out = handle->history_events[handle->history_events_head++];
  handle->history_events_len -= 1;
  if (!handle->history_events_len) handle->history_events_head = 0;
  return 1;
}

void msr_vterm_free_history_event(msr_vterm_history_event *event) {
  if (!event) return;
  free(event->cells);
  event->cells = NULL;
}
