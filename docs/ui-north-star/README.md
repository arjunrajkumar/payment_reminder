# Receivables UI north star

Captured on July 14, 2026 with disposable test-only customer and invoice data.

The `before-` screenshots preserve the original visual direction, including the
prototype-only payment summaries and conversations. The `after-` screenshots
are the current product baseline: every displayed value comes from persisted
customers and invoices.

Until communication is persisted, these screens should show only:

- customer identity;
- outstanding, overdue, open, paid, and uncollectible invoice facts;
- payer segments inferred from persisted due dates and payment dates; and
- invoice timing.

Customer status follows this precedence: overdue, outstanding, uncollectible,
open with no balance due, then paid.

Do not add reminder, reply, schedule, dispute, or conversation claims to these
screens until the corresponding records and workflow exist.

## Before cleanup

![Receivables inbox before cleanup](before-home-inbox.png)

![Remaining inbox states before cleanup](before-home-inbox-bottom.png)

![Harbor and Co before cleanup](before-customer-harbor-top.png)

![Prototype Harbor conversation](before-customer-harbor-conversation.png)

![Nat Dogre before cleanup](before-customer-nat-dogre-top.png)

![Prototype Nat Dogre conversation](before-customer-nat-dogre-conversation.png)

## Persisted-facts baseline

![Receivables inbox after cleanup](after-home-inbox.png)

![Remaining inbox states after cleanup](after-home-inbox-bottom.png)

![Harbor and Co after cleanup](after-customer-harbor.png)

![Nat Dogre after cleanup](after-customer-nat-dogre.png)
