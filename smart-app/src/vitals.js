// The clinical logic, kept free of FHIR shapes and the DOM so it can be tested directly.

/**
 * Vitals are matched by CIEL concept code, not LOINC.
 *
 * That is not a preference. Measured against OpenMRS FHIR2 4.2.0 demo data, LOINC covers exactly one
 * of these eight concepts (diastolic blood pressure); SNOMED covers five; CIEL covers all eight. An app
 * that matches on LOINC alone — the obvious thing to write — finds one vital and renders seven empty
 * charts, which looks like missing data rather than a coding mismatch.
 *
 * Each entry lists every system it has been seen under, most complete first, so a server that codes
 * these differently still resolves.
 */
export const VITALS = [
	{ key: 'systolic', label: 'Systolic BP', unit: 'mmHg', ciel: '5085', snomed: '271649006' },
	{ key: 'diastolic', label: 'Diastolic BP', unit: 'mmHg', ciel: '5086', loinc: '35094-2', snomed: '271650006' },
	{ key: 'pulse', label: 'Pulse', unit: 'beats/min', ciel: '5087', snomed: '78564009' },
	{ key: 'temperature', label: 'Temperature', unit: '°C', ciel: '5088' },
	{ key: 'weight', label: 'Weight', unit: 'kg', ciel: '5089' },
	{ key: 'height', label: 'Height', unit: 'cm', ciel: '5090' },
	{ key: 'spo2', label: 'Oxygen saturation', unit: '%', ciel: '5092', snomed: '431314004' },
	{ key: 'respiratory', label: 'Respiratory rate', unit: 'breaths/min', ciel: '5242', snomed: '86290005' },
];

const SYSTEMS = { ciel: 'https://cielterminology.org', loinc: 'http://loinc.org', snomed: 'http://snomed.info/sct/' };

/** Which vital, if any, an Observation carries. Returns the entry from VITALS, or null. */
export function classifyObservation(observation) {
	const codings = observation?.code?.coding ?? [];

	for (const vital of VITALS) {
		for (const axis of ['ciel', 'loinc', 'snomed']) {
			if (!vital[axis]) continue;
			if (codings.some((c) => c.code === vital[axis] && (!c.system || c.system === SYSTEMS[axis]))) {
				return vital;
			}
		}
	}

	return null;
}

/**
 * Reference ranges. Blood pressure follows the 2017 ACC/AHA stages; the rest are the adult ranges a
 * triage nurse works to. Deliberately adult-only: applying them to a child would be wrong in a way
 * that looks authoritative, so `interpret` is given the age and declines rather than guesses.
 */
const RANGES = {
	systolic: { low: 90, high: 120, stages: [[180, 'crisis'], [140, 'stage 2'], [130, 'stage 1'], [120, 'elevated']] },
	diastolic: { low: 60, high: 80, stages: [[120, 'crisis'], [90, 'stage 2'], [80, 'stage 1']] },
	pulse: { low: 60, high: 100 },
	temperature: { low: 36.1, high: 37.5, stages: [[38, 'fever']] },
	spo2: { low: 95, high: 100, stages: [] },
	respiratory: { low: 12, high: 20 },
};

/**
 * Reads a single value against its reference range.
 *
 * `status` is one of 'normal', 'low', 'high', or 'unknown' — 'unknown' when there is no adult range
 * for the concept, or when the patient is under 18 and the adult range does not apply.
 */
export function interpret(key, value, ageYears) {
	const range = RANGES[key];

	if (range == null || value == null) return { status: 'unknown' };
	if (ageYears != null && ageYears < 18) return { status: 'unknown', note: 'adult ranges only' };

	for (const [threshold, label] of range.stages ?? []) {
		if (value >= threshold) return { status: 'high', label };
	}

	if (value > range.high) return { status: 'high' };
	if (value < range.low) return { status: 'low' };

	return { status: 'normal' };
}

/**
 * Body mass index from height and weight, which OpenMRS stores neither of as a computed value: this is
 * the app doing arithmetic no server handed it. Returns null unless both are present and plausible,
 * because a BMI derived from a mis-keyed height is worse than no BMI at all.
 */
export function bmi(heightCm, weightKg) {
	if (!heightCm || !weightKg) return null;
	if (heightCm < 50 || heightCm > 250 || weightKg < 2 || weightKg > 500) return null;

	const metres = heightCm / 100;
	const value = weightKg / (metres * metres);

	return Math.round(value * 10) / 10;
}

/** The WHO categories, which is what a BMI is actually read for. */
export function bmiCategory(value) {
	if (value == null) return null;
	if (value < 18.5) return 'underweight';
	if (value < 25) return 'healthy weight';
	if (value < 30) return 'overweight';
	return 'obese';
}

/** Whole years between a birth date and a reference date, or null if the birth date is unusable. */
export function ageYears(birthDate, on = new Date()) {
	if (!birthDate) return null;

	const born = new Date(birthDate);
	if (Number.isNaN(born.getTime())) return null;

	let age = on.getFullYear() - born.getFullYear();
	const monthsBefore = on.getMonth() - born.getMonth();
	if (monthsBefore < 0 || (monthsBefore === 0 && on.getDate() < born.getDate())) age -= 1;

	return age < 0 || age > 130 ? null : age;
}
