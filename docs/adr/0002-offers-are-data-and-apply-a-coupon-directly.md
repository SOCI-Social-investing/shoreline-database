# Offers are data, and checkout applies a coupon directly

The first signup offer (holiday26: 3 months of plan fees free) was hard-coded in
both the backend and the SPA, with its Stripe promotion code in an env var. Every
new campaign would have meant matching code changes in two repos, two deploys and
a new env var, and one mismatched end date would have the banner promise an offer
the server refuses. It also had two holes: the offer lived only in the browser's
localStorage (lost on another device, shared by anyone using the same browser),
and Stripe promotion codes can be typed into any checkout that allows promotion
codes — including a yearly one, where a 3-month coupon frees the whole first
annual invoice.

We store campaigns in `offers` and a Company's claim in `company_offers`. The SPA
passes the link's code to signup; the backend records the claim against the new
Company; checkout applies `offers.stripe_coupon_id` only for a Company with an
unredeemed claim on a live offer, for an eligible plan and billing term; the
subscription webhook marks the claim redeemed.

## Considered options

- **Keep the hard-coded definitions, add a `companies.signup_offer` column.**
  Fixes the cross-device problem but keeps the two-repo, deploy-per-campaign
  cost. Rejected because more campaigns are planned.
- **Keep Stripe promotion codes for the "first-time customer" restriction.**
  Rejected: a promotion code is customer-typeable wherever Checkout allows
  promotion codes, which our checkout does for ordinary plans. A coupon cannot be
  typed. "New customers only" is enforced by the claim instead: claims are only
  made at signup, for a brand-new Company, and redeemed once.

## Consequences

- Adding a campaign is one `INSERT` per environment (staging and production have
  separate Stripe accounts, so separate coupon ids). Switching one off is
  `is_active = false`.
- The coupon's own Stripe settings (percent, duration, `applies_to` products,
  `redeem_by`) still bound the discount. Because every plan tier's monthly and
  yearly prices can share one Stripe product, eligibility is checked by the
  backend, not by the coupon: the chosen price must be in the row's
  `eligible_price_ids` and bill on one of its `eligible_terms`
  (`20261127030000`). Listing exact prices on the row, rather than mapping
  prices to tiers through backend env settings, means each environment's row
  is self-contained — staging's tier settings were incomplete and refused
  every offer checkout. `eligible_plans` only feeds the banner's fine print.
- A claimed offer can't be deleted (`ON DELETE RESTRICT`); it is history.
- Existing Companies can be given an offer by inserting a `company_offers` row.
