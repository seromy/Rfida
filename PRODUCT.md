# Product

<!-- impeccable:product-schema 1 -->

> Inferred from the repository and the user's brief ("SAP-style inventory web interface, device loaning service, no mobile app work"). The init interview was skipped because the user asked to proceed without questions; every fact below marked *(inferred)* has not been confirmed.

## Platform

web

## Stack

Existing: Flask + Flask-SQLAlchemy + SQLite, server-rendered Jinja2 templates, plain CSS/JS (no build step). Kept as is.

## Users

- Office staff of a small photography/video production house *(inferred)*. They sit at a desk with a desktop browser and manage equipment master data, jobs, loans and audit questions ("where is the A7IV?", "who has the 70-200 and when is it due?").
- Field crew use the iPhone handheld app; they never open this dashboard. The iOS app is out of scope for this work.

## Product Purpose

RFID-based equipment check-in/out and inventory for a photography equipment pool. The web dashboard is the system of record: equipment master, companies/clients, jobs, movements from the handheld, inventory counts, and the device-loaning service (lend equipment to a borrower with a due date, track overdue, take it back with a condition check).

## Operating Context

- Trusted office network, no login (scheme document section 9). Do not add auth without being asked.
- UI language is Traditional Chinese (Hong Kong Cantonese register in copy), times shown in Hong Kong time.
- The REST API contract in `docs/API_CONTRACT.md` is consumed by the shipped iOS app and must stay backward compatible (equipment `status` is a strict enum of `in_stock` / `checked_out` / `missing`).

## Capabilities and Constraints

- Equipment status values are fixed by the iOS app. "On loan" is therefore derived from open loan items, not a new status value.
- Data volume is small (hundreds of items), SQLite, single office.

## Brand Commitments

User asked for an **SAP Fiori-style** interface: shell bar, side navigation, launchpad tiles, list reports with filter bars, object pages with tabs, document numbers, change documents. That is the binding visual direction.

## Product Principles

1. Every business object has a document number, a list report, an object page, and a change log.
2. Status is shown with semantic colour and icon, never colour alone.
3. The server decides state transitions; the UI only offers the legal ones.
4. The handheld API never breaks.
