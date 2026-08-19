// Turning a bundle of Observations into something chartable, and reading the result.

import { VITALS, classifyObservation, bmi, bmiCategory, interpret } from './vitals.js';

/** The instant an Observation applies to. Falls back through the fields OpenMRS actually populates. */
function observedAt(observation) {
	return observation.effectiveDateTime ?? observation.effectivePeriod?.start ?? observation.issued ?? null;
}

/**
 * Groups a bundle's Observations into one time series per vital, each sorted oldest first.
 *
 * Only quantities are kept. A vital recorded as text — which happens — cannot be plotted or compared,
 * and silently coercing it would invent a number the record does not contain.
 */
export function toSeries(bundle) {
	const series = new Map(VITALS.map((v) => [v.key, []]));

	for (const entry of bundle?.entry ?? []) {
		const observation = entry.resource;
		if (observation?.resourceType !== 'Observation') continue;

		const vital = classifyObservation(observation);
		const at = observedAt(observation);
		const value = observation.valueQuantity?.value;

		if (!vital || at == null || typeof value !== 'number') continue;

		series.get(vital.key).push({ at, value, encounter: observation.encounter?.reference ?? null });
	}

	for (const points of series.values()) points.sort((a, b) => a.at.localeCompare(b.at));

	return series;
}

/**
 * Pairs height and weight recorded on the same day into a BMI series.
 *
 * Same day rather than same instant: height and weight are entered as separate observations during one
 * visit and their timestamps differ by seconds to minutes. Pairing on the exact instant produced an
 * empty series against real data, which is how this rule was arrived at.
 */
export function bmiSeries(series) {
	const heights = new Map((series.get('height') ?? []).map((p) => [p.at.slice(0, 10), p.value]));
	const points = [];

	for (const weight of series.get('weight') ?? []) {
		const day = weight.at.slice(0, 10);
		const value = bmi(heights.get(day), weight.value);
		if (value != null) points.push({ at: weight.at, value, category: bmiCategory(value) });
	}

	return points;
}

/** The most recent point of each series, read against its reference range. */
export function latest(series, age) {
	const rows = [];

	for (const vital of VITALS) {
		const points = series.get(vital.key) ?? [];
		if (points.length === 0) continue;

		const point = points[points.length - 1];
		const previous = points.length > 1 ? points[points.length - 2] : null;

		rows.push({
			...vital,
			value: point.value,
			at: point.at,
			delta: previous ? Math.round((point.value - previous.value) * 10) / 10 : null,
			reading: interpret(vital.key, point.value, age),
		});
	}

	return rows;
}

/**
 * The one line a clinician reads first. Counts only vitals with an applicable range, so "0 of 0" is
 * reported honestly rather than presented as a clean bill of health.
 */
export function summarise(rows) {
	const assessable = rows.filter((r) => r.reading.status !== 'unknown');
	const outside = assessable.filter((r) => r.reading.status !== 'normal');

	return { assessable: assessable.length, outside: outside.length, names: outside.map((r) => r.label) };
}

/** How definite a clinical status is, for choosing between duplicates. */
const STATUS_RANK = { active: 4, recurrence: 4, relapse: 4, inactive: 3, remission: 3, resolved: 3, unknown: 1 };

/**
 * Collapses a Condition bundle to one entry per problem.
 *
 * OpenMRS FHIR2 4.2.0 returns two Condition resources per problem against demo data — same concept,
 * different ids, one with `clinicalStatus` of `active` and one of `unknown`. Rendering the bundle
 * verbatim shows every diagnosis twice, which reads as an application fault. Grouping by concept and
 * keeping the most definite status is what a reader expects, and it is safe on a server that does not
 * duplicate: there, each group has one member.
 */
export function problemList(bundle) {
	const groups = new Map();

	for (const entry of bundle?.entry ?? []) {
		const condition = entry.resource;
		if (condition?.resourceType !== 'Condition') continue;

		const coding = condition.code?.coding ?? [];
		const name = coding.find((c) => c.display)?.display ?? condition.code?.text ?? null;
		// Group on a code where there is one; a display string is the fallback, not the key of choice.
		const key = coding.find((c) => c.code)?.code ?? name;
		if (key == null) continue;

		const status = condition.clinicalStatus?.coding?.[0]?.code ?? 'unknown';
		const onset = condition.onsetDateTime ?? null;
		const held = groups.get(key);

		if (!held) {
			groups.set(key, { name: name ?? '(unnamed condition)', status, onset });
			continue;
		}

		// Each field is decided on its own merit: the most definite status wins, and an onset date is
		// kept from whichever duplicate carries one. Replacing the whole record would let a duplicate
		// with an onset overwrite the better status, and one with a status discard the onset.
		const better = (STATUS_RANK[status] ?? 0) > (STATUS_RANK[held.status] ?? 0);

		groups.set(key, {
			name: held.name ?? name ?? '(unnamed condition)',
			status: better ? status : held.status,
			onset: held.onset ?? onset,
		});
	}

	return [...groups.values()].sort((a, b) => a.name.localeCompare(b.name));
}
