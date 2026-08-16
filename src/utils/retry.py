"""
Retry-with-backoff helpers for flaky network calls.

Provides a single `retry_call` wrapper used by the SteamCMD REST API and
Steam PICS call sites. Pure stdlib (no `requests` dependency) so it works
with both `requests`-style and `urllib`-style callables.

Retry policy:
  * transient exceptions (timeouts, connection errors, DNS) are retried
  * HTTP errors with a deterministic client status (400/404/401/...) are
    NOT retried and propagate immediately
  * responses whose status code is in `retry_statuses` (default 429/5xx)
    are retried
  * backoff is exponential with jitter:
        delay = min(base_delay * 2 ** attempt, max_delay) * (0.5..1.0)
"""

import logging
import random
import time

logger = logging.getLogger(__name__)

# Statuses worth retrying — transient server-side failures.
DEFAULT_RETRY_STATUSES = frozenset({429, 500, 502, 503, 504})

# Client-side statuses that will never succeed on retry — fail fast.
NON_RETRYABLE_STATUSES = frozenset(
    {400, 401, 403, 404, 405, 406, 408, 409, 410, 422, 451}
)


def backoff_delay(attempt: int, base_delay: float = 0.5, max_delay: float = 5.0) -> float:
    """Exponential backoff with jitter for the given 0-based attempt."""
    delay = min(base_delay * (2 ** attempt), max_delay)
    if delay > 0:
        delay *= 0.5 + random.random() / 2  # jitter: 50%..100% of computed delay
    return delay


def _extract_http_status(exc_or_resp) -> int | None:
    """Best-effort extraction of an HTTP status from an exception or response."""
    code = getattr(exc_or_resp, "code", None)
    if code is not None:
        return int(code)
    resp = getattr(exc_or_resp, "response", None)
    if resp is not None:
        code = getattr(resp, "status_code", None)
        if code is not None:
            return int(code)
    return None


def retry_call(
    fn,
    *,
    attempts: int = 3,
    base_delay: float = 0.5,
    max_delay: float = 5.0,
    retry_statuses=DEFAULT_RETRY_STATUSES,
    log_prefix: str = "request",
    log: logging.Logger = logger,
):
    """
    Call `fn()` up to `attempts` times with exponential backoff + jitter.

    `fn` must either raise on failure or return a response-like object that
    has a `status_code` / `getcode()` attribute.

    Returns `fn()`'s return value on success. Non-retryable HTTP errors
    propagate immediately. If all attempts fail, the last exception is
    re-raised (or None is returned when attempts were exhausted on transient
    HTTP statuses without any exception being raised).
    """
    last_exc = None
    for attempt in range(attempts):
        try:
            result = fn()
        except Exception as e:  # noqa: BLE001 - retry layer catches everything
            last_exc = e
            status = _extract_http_status(e)
            if status is not None and status in NON_RETRYABLE_STATUSES:
                raise
            if log:
                log.debug(f"{log_prefix} attempt {attempt + 1}/{attempts} failed: {e}")
            if attempt < attempts - 1:
                time.sleep(backoff_delay(attempt, base_delay, max_delay))
            continue

        # Success path — retry transient HTTP statuses on the response itself.
        status = getattr(result, "status_code", None)
        if status is None and hasattr(result, "getcode"):
            try:
                status = result.getcode()
            except Exception:
                status = None
        if status is not None and int(status) in retry_statuses:
            if log:
                log.warning(
                    f"{log_prefix} returned HTTP {status} "
                    f"(attempt {attempt + 1}/{attempts})"
                )
            if attempt < attempts - 1:
                time.sleep(backoff_delay(attempt, base_delay, max_delay))
            continue
        return result

    if last_exc is not None:
        raise last_exc
    return None
