/* Real Windows IPC deadline helper. No mocks: callbacks use owned duplicated
 * thread handles and Win32 cancellation; they never call Nim code. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>

typedef struct {
  HANDLE thread;
  HANDLE timer;
  volatile LONG expired;
  HANDLE first_cancel_done;
  DWORD first_cancel_error;
} tac_deadline;

static VOID CALLBACK tac_cancel_operation(PVOID opaque, BOOLEAN timer_fired) {
  tac_deadline *deadline = (tac_deadline *)opaque;
  (void)timer_fired;
  LONG first = InterlockedCompareExchange(&deadline->expired, 1, 0) == 0;
  BOOL canceled = CancelSynchronousIo(deadline->thread);
  DWORD error = canceled ? ERROR_SUCCESS : GetLastError();
  /* Repeat cancellation through gaps between synchronous calls until finish
   * joins all callbacks. An expired operation can never count as a success. */
  if (first) {
    deadline->first_cancel_error = error;
    SetEvent(deadline->first_cancel_done);
  }
}

void *tac_start_operation_deadline(void) {
  tac_deadline *deadline = (tac_deadline *)calloc(1, sizeof(*deadline));
  if (!deadline) return NULL;
  if (!DuplicateHandle(GetCurrentProcess(), GetCurrentThread(),
                       GetCurrentProcess(), &deadline->thread, 0, FALSE,
                       DUPLICATE_SAME_ACCESS)) {
    free(deadline);
    return NULL;
  }
  deadline->first_cancel_done = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (!deadline->first_cancel_done) {
    CloseHandle(deadline->thread);
    free(deadline);
    return NULL;
  }
  if (!CreateTimerQueueTimer(&deadline->timer, NULL, tac_cancel_operation,
                            deadline, 5000, 10, WT_EXECUTEDEFAULT)) {
    CloseHandle(deadline->first_cancel_done);
    CloseHandle(deadline->thread);
    free(deadline);
    return NULL;
  }
  return deadline;
}

int tac_finish_operation_deadline(void *opaque) {
  tac_deadline *deadline = (tac_deadline *)opaque;
  LONG expired;
  if (!deadline) return -1;
  /* Waiting prevents callback access after releasing its context. */
  if (!DeleteTimerQueueTimer(NULL, deadline->timer, INVALID_HANDLE_VALUE)) {
    /* Unknown callback lifetime: preserve owned resources, fail the harness. */
    return -1;
  }
  expired = InterlockedCompareExchange(&deadline->expired, 0, 0);
  CloseHandle(deadline->first_cancel_done);
  CloseHandle(deadline->thread);
  free(deadline);
  return expired ? 1 : 0;
}

static VOID CALLBACK tac_end_fixture(PVOID ignored, BOOLEAN timer_fired) {
  (void)ignored;
  (void)timer_fired;
  TerminateProcess(GetCurrentProcess(), 125);
}

HANDLE tac_start_fixture_deadline(void) {
  HANDLE timer = NULL;
  if (!CreateTimerQueueTimer(&timer, NULL, tac_end_fixture, NULL,
                            10000, 0, WT_EXECUTEONLYONCE)) return NULL;
  return timer;
}

int tac_finish_fixture_deadline(HANDLE timer) {
  if (!timer) return -1;
  return DeleteTimerQueueTimer(NULL, timer, INVALID_HANDLE_VALUE) ? 0 : -1;
}

/* Genuine gap control: the first cancellation runs with no pending I/O, then
 * a real named-pipe read begins and must be canceled by a later callback. */
int tac_between_calls_timeout(const WCHAR *path) {
  HANDLE pipe = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  tac_deadline *deadline;
  DWORD count = 0, read_error = 0, first_error = 0;
  const char request[] = "{\"cmd\":\"ping\"}\n";
  char ch;
  int finished, valid = 0;
  ULONGLONG started;
  if (pipe == INVALID_HANDLE_VALUE) return 1;
  deadline = (tac_deadline *)tac_start_operation_deadline();
  if (!deadline) { CloseHandle(pipe); return 2; }
  started = GetTickCount64();
  if (!WriteFile(pipe, request, sizeof(request) - 1, &count, NULL) ||
      count != sizeof(request) - 1) goto done;
  if (WaitForSingleObject(deadline->first_cancel_done, 6000) != WAIT_OBJECT_0)
    goto done;
  first_error = deadline->first_cancel_error;
  if (!ReadFile(pipe, &ch, 1, &count, NULL)) read_error = GetLastError();
  valid = first_error == ERROR_NOT_FOUND && read_error == ERROR_OPERATION_ABORTED;
done:
  finished = tac_finish_operation_deadline(deadline);
  printf("between-call timeout first_error=%lu read_error=%lu elapsed_ms=%llu finish=%d\n",
         (unsigned long)first_error, (unsigned long)read_error,
         (unsigned long long)(GetTickCount64() - started), finished);
  CloseHandle(pipe);
  return valid && finished == 1 ? 0 : 3;
}
