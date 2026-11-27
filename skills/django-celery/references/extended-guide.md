# django-celery — Extended Reference

## Anti-Patterns

```python
# BAD: Passing model instances — they may be stale by execution time
send_welcome_email.delay(user)        # Never pass ORM objects
send_welcome_email.delay(user.pk)     # Always pass PKs

# BAD: Calling tasks synchronously in production views
result = generate_report.apply()      # Blocks the request thread

# BAD: Non-idempotent task without guards
@shared_task
def charge_and_fulfill(order_id):
    order.charge()     # May charge twice if task retries!
    order.fulfill()

# GOOD: Claim ownership before external I/O, then finalize only as that owner
from django.db import transaction
from apps.payments.gateway import gateway

@shared_task(bind=True, acks_late=True)
def charge_and_fulfill(self, order_id):
    attempt_id = self.request.id  # Stable across Celery retry and redelivery
    with transaction.atomic():
        order = Order.objects.select_for_update().get(pk=order_id)
        if not order.claim_or_resume_charge(attempt_id):
            return

    # The adapter validates provider data and returns the same charge on retry.
    receipt = gateway.charge(order_id, idempotency_key=f'order:{order_id}')

    with transaction.atomic():
        order = Order.objects.select_for_update().get(pk=order_id)
        if order.charge_attempt_id != attempt_id:
            return
        order.record_charge(receipt)
        order.fulfill()
```

## Production Checklist

| Check | Setting |
|-------|---------|
| Worker restarts on crash | `supervisord` or `systemd` unit |
| Late acknowledgement | Per task, only after proving idempotency; duplicates remain possible |
| Worker-loss redelivery | `task_reject_on_worker_lost`, opt in only with poison-task protection |
| `CELERY_WORKER_PREFETCH_MULTIPLIER = 1` | Fair distribution of long tasks |
| Separate queues per priority | `-Q default,high_priority,low_priority` |
| `CELERY_TASK_SOFT_TIME_LIMIT` set | Graceful timeout before hard kill |
| Sentry integration | Capture all `task_failure` signals |
| Flower or other monitor | Visibility into queue depths |
| Beat runs on single node only | Prevents duplicate scheduled task publication |
| Periodic-task locking | Prevents overlapping execution when required |

## References

- [Celery task acknowledgement and idempotency](https://docs.celeryq.dev/en/stable/userguide/tasks.html)
- [Celery configuration defaults](https://docs.celeryq.dev/en/stable/userguide/configuration.html)
- [Celery with Django transaction handling](https://docs.celeryq.dev/en/stable/django/first-steps-with-django.html)
- [Celery periodic tasks](https://docs.celeryq.dev/en/stable/userguide/periodic-tasks.html)
- [Celery testing guide](https://docs.celeryq.dev/en/stable/userguide/testing.html)

## Related Skills

- `django-patterns` — ORM, service layer, and project structure
- `django-tdd` — Testing Django models, views, and services
- `python-testing` — pytest configuration and fixtures
