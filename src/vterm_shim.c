#include "vterm_shim.h"
#include <stdlib.h>

msr_vterm_handle *msr_vterm_new(int rows, int cols) {
  msr_vterm_handle *h = (msr_vterm_handle *)calloc(1, sizeof(msr_vterm_handle));
  if (!h) return NULL;
  h->vt = vterm_new(rows, cols);
  if (!h->vt) {
    free(h);
    return NULL;
  }
  h->screen = vterm_obtain_screen(h->vt);
  vterm_screen_enable_altscreen(h->screen, 1);
  vterm_screen_reset(h->screen, 1);
  vterm_screen_flush_damage(h->screen);
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
  if (handle->screen) vterm_screen_flush_damage(handle->screen);
}

void msr_vterm_feed(msr_vterm_handle *handle, const char *bytes, size_t len) {
  if (!handle || !handle->vt) return;
  vterm_input_write(handle->vt, bytes, len);
  if (handle->screen) vterm_screen_flush_damage(handle->screen);
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
  if (visible) *visible = 1;
}

int msr_vterm_get_alt_screen(msr_vterm_handle *handle) {
  (void)handle;
  return 0;
}

uint32_t msr_vterm_get_cell_codepoint(msr_vterm_handle *handle, int row, int col) {
  if (!handle || !handle->screen) return 0;
  VTermScreenCell cell;
  VTermPos pos = { row, col };
  if (!vterm_screen_get_cell(handle->screen, pos, &cell)) return 0;
  return cell.chars[0];
}
