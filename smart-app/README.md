smart-vitals-review-app
=======================

A SMART on FHIR application that reviews a patient's vitals: it trends every recorded series, derives
values the server does not store, and reads each one against a reference range. It is a demonstration
app, but it is not a record viewer — everything on the page is either a measurement or something
computed from measurements.

Written against [SMART App Launch 2.x](https://hl7.org/fhir/smart-app-launch/) using
[fhirclient](https://github.com/smart-on-fhir/client-js), the reference JavaScript library, so that it
exercises the path a third-party integrator actually takes rather than a hand-rolled one. Nothing in it
is OpenMRS-specific except the concept codes noted below.

## What it shows

- **Eight vitals trended** — systolic and diastolic pressure, pulse, temperature, respiratory rate,
  oxygen saturation, weight and height — each with its reference band shaded and each point hoverable.
- **A headline count** of how many of the latest vitals fall outside range, naming them. Only vitals
  with an applicable range are counted, so "0 of 0" is never dressed up as a clean bill of health.
- **Body mass index, derived.** OpenMRS stores height and weight and no BMI, so every value in that
  card was computed here, categorised by the WHO bands and trended over time.
- **Reference-range readings** using the 2017 ACC/AHA blood-pressure stages and the adult ranges a
  triage nurse works to. Deliberately adult-only: for a patient under 18 the app reports no verdict
  rather than applying an adult range, because a wrong reading that looks authoritative is worse than
  an absent one.
- **The problem list and visit history**, and when the app is launched for a specific visit, that
  visit's readings ringed and its entry marked.

## Launch context is used, not merely received

The app is registered twice in the demonstration distribution, and the difference is the point:

| Registered as | Launch context | What changes |
|---|---|---|
| `vitals-review` | patient | the whole record is reviewed |
| `vitals-review-visit` | encounter | the launched visit's readings are ringed, and it is marked in the visit list |

When launched for a visit that recorded no vitals, the app says so instead of promising highlights it
cannot deliver.

## Running it

```bash
npm install
npm run build
npm start           # serves on http://localhost:3001
```

It needs a SMART-capable FHIR server. Against the
[SMART on FHIR distribution](https://github.com/mherman22/openmrs-distro-smartonfhir), `./up.sh`
registers this app already; start that stack, serve this app on 3001, and launch it from a patient
chart.

The client id defaults to `smartClient` and can be overridden with a `client_id` query parameter on the
launch URL. The redirect URI is `index.html`, relative to wherever the app is served.

## Scopes

```
launch openid fhirUser patient/Patient.rs patient/Observation.rs patient/Condition.rs patient/Encounter.rs
```

Only what it reads. Asking for more would be refused outright by a server that enforces scopes, and on
one that does not it would take privileges the app has no use for.

## Two things measured about OpenMRS's FHIR output

Both were found by running this app against OpenMRS FHIR2 4.2.0, and both would bite any integrator.

**Vitals are not reliably LOINC-coded.** Of the eight concepts this app reads, LOINC covers exactly one
(diastolic blood pressure, `35094-2`); SNOMED covers five; CIEL covers all eight. An app matching on
LOINC alone — the obvious thing to write — finds one vital and renders seven empty charts, which looks
like missing data rather than a coding mismatch. This app matches on CIEL first and falls back to LOINC
and SNOMED, and `src/vitals.js` records which axis covers what.

**Conditions arrive duplicated.** The server returns two `Condition` resources per problem — same
concept, different ids, one with `clinicalStatus` `active` and one `unknown` — so a patient with
sixteen problems yields a bundle of thirty-two. Rendering that verbatim shows every diagnosis twice.
`problemList` groups by concept and keeps the most definite status, which is a no-op on a server that
does not duplicate.

## Tests

```bash
npm test
```

Nineteen tests over the parts that reason rather than render: concept matching, the reference ranges,
the BMI derivation and its plausibility guards, series construction, and the Condition collapse. Every
one uses codings and values copied from real server output rather than invented, and each guard has
been checked by reintroducing the defect and watching the test fail.

The rendering is verified by launching the app in a browser against the distribution, which is the only
thing that establishes a launch works end to end.

## A caveat about the demonstration data

The RefApp demo data is synthetic, and its vitals move in ways real ones do not — a middle-aged
patient gains seventeen centimetres of height across the series. The app computes faithfully from what
it is given, so the trends are as noisy as the data. That is the correct behaviour, and it is worth
knowing before reading a demonstration as a clinical narrative.
