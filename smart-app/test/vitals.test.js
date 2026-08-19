import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyObservation, interpret, bmi, bmiCategory, ageYears } from '../src/vitals.js';
import { toSeries, bmiSeries, latest, summarise, problemList } from '../src/series.js';

// The codings below are copied from OpenMRS FHIR2 4.2.0 demo data, not invented, because the point of
// these tests is that this app reads what that server actually emits.
const obs = (codings, value, at, unit = 'x') => ({
	resourceType: 'Observation',
	code: { coding: codings },
	valueQuantity: { value, unit },
	effectiveDateTime: at,
});

const ciel = (code) => ({ system: 'https://cielterminology.org', code });

test('classifyObservation matches a vital by its CIEL code', () => {
	assert.equal(classifyObservation(obs([ciel('5085')], 156, '2026-01-11')).key, 'systolic');
	assert.equal(classifyObservation(obs([ciel('5242')], 13, '2026-01-11')).key, 'respiratory');
});

test('classifyObservation matches on LOINC or SNOMED when that is all a server sends', () => {
	assert.equal(classifyObservation(obs([{ system: 'http://loinc.org', code: '35094-2' }], 41, 'x')).key, 'diastolic');
	assert.equal(classifyObservation(obs([{ system: 'http://snomed.info/sct/', code: '78564009' }], 64, 'x')).key, 'pulse');
});

test('classifyObservation ignores an observation it has no concept for', () => {
	assert.equal(classifyObservation(obs([ciel('1132')], 140, 'x')), null); // serum sodium
	assert.equal(classifyObservation({ resourceType: 'Observation' }), null);
});

// A code that matches the digits but belongs to another system must not resolve, or every server
// numbering its concepts 5085 would be read as a blood pressure.
test('classifyObservation does not match a code from an unrelated system', () => {
	assert.equal(classifyObservation(obs([{ system: 'http://example.org/codes', code: '5085' }], 156, 'x')), null);
});

test('interpret stages blood pressure the way ACC/AHA does', () => {
	assert.equal(interpret('systolic', 118, 40).status, 'normal');
	assert.equal(interpret('systolic', 124, 40).label, 'elevated');
	assert.equal(interpret('systolic', 134, 40).label, 'stage 1');
	assert.equal(interpret('systolic', 156, 40).label, 'stage 2'); // the demo patient's latest
	assert.equal(interpret('systolic', 185, 40).label, 'crisis');
});

test('interpret reads a value below range as low, not merely abnormal', () => {
	assert.equal(interpret('diastolic', 41, 40).status, 'low'); // the demo patient's latest
	assert.equal(interpret('pulse', 44, 40).status, 'low');
	assert.equal(interpret('spo2', 88, 40).status, 'low');
});

test('interpret declines rather than applying adult ranges to a child', () => {
	assert.equal(interpret('pulse', 120, 4).status, 'unknown');
	assert.equal(interpret('pulse', 120, 40).status, 'high');
});

test('interpret declines a concept it has no range for', () => {
	assert.equal(interpret('weight', 88, 40).status, 'unknown');
	assert.equal(interpret('height', 152, 40).status, 'unknown');
});

test('bmi computes from height and weight, and categorises', () => {
	assert.equal(bmi(152, 88), 38.1); // the demo patient
	assert.equal(bmiCategory(38.1), 'obese');
	assert.equal(bmiCategory(22), 'healthy weight');
	assert.equal(bmiCategory(18.4), 'underweight');
	assert.equal(bmiCategory(27), 'overweight');
});

test('bmi refuses implausible input rather than returning a number', () => {
	assert.equal(bmi(0, 88), null);
	assert.equal(bmi(152, 0), null);
	assert.equal(bmi(20, 88), null); // height in inches, mis-entered
	assert.equal(bmi(152, 900), null);
	assert.equal(bmi(null, 88), null);
});

test('ageYears counts whole years and rejects nonsense', () => {
	assert.equal(ageYears('1990-06-15', new Date('2026-06-14')), 35);
	assert.equal(ageYears('1990-06-15', new Date('2026-06-15')), 36);
	assert.equal(ageYears(null), null);
	assert.equal(ageYears('not a date'), null);
});

test('toSeries groups by vital and orders oldest first', () => {
	const bundle = { entry: [
		{ resource: obs([ciel('5085')], 156, '2026-01-11') },
		{ resource: obs([ciel('5085')], 130, '2022-11-28') },
		{ resource: obs([ciel('5087')], 64, '2026-01-11') },
	] };
	const series = toSeries(bundle);

	assert.deepEqual(series.get('systolic').map((p) => p.value), [130, 156]);
	assert.equal(series.get('pulse').length, 1);
	assert.equal(series.get('weight').length, 0);
});

// A vital recorded as text cannot be plotted; coercing it would invent a reading.
test('toSeries drops an observation with no numeric value', () => {
	const bundle = { entry: [{ resource: { resourceType: 'Observation', code: { coding: [ciel('5085')] },
		valueString: 'not recorded', effectiveDateTime: '2026-01-11' } }] };

	assert.equal(toSeries(bundle).get('systolic').length, 0);
});

// Height and weight arrive as separate observations minutes apart. Pairing on the exact instant found
// nothing against real data; this is the test that pins the day-level rule.
test('bmiSeries pairs height and weight recorded on the same day', () => {
	const series = toSeries({ entry: [
		{ resource: obs([ciel('5090')], 152, '2026-01-11T09:00:00Z') },
		{ resource: obs([ciel('5089')], 88, '2026-01-11T09:04:00Z') },
		{ resource: obs([ciel('5089')], 90, '2025-01-11T09:04:00Z') }, // no height that day
	] });
	const points = bmiSeries(series);

	assert.equal(points.length, 1);
	assert.equal(points[0].value, 38.1);
	assert.equal(points[0].category, 'obese');
});

test('latest reports the most recent value and its change', () => {
	const series = toSeries({ entry: [
		{ resource: obs([ciel('5085')], 130, '2022-11-28') },
		{ resource: obs([ciel('5085')], 156, '2026-01-11') },
	] });
	const rows = latest(series, 40);

	assert.equal(rows.length, 1);
	assert.equal(rows[0].value, 156);
	assert.equal(rows[0].delta, 26);
	assert.equal(rows[0].reading.label, 'stage 2');
});

test('summarise counts only vitals it can actually assess', () => {
	const series = toSeries({ entry: [
		{ resource: obs([ciel('5085')], 156, '2026-01-11') }, // stage 2  -> outside
		{ resource: obs([ciel('5087')], 64, '2026-01-11') },  // normal
		{ resource: obs([ciel('5089')], 88, '2026-01-11') },  // weight, no range
	] });
	const summary = summarise(latest(series, 40));

	assert.equal(summary.assessable, 2);
	assert.equal(summary.outside, 1);
	assert.deepEqual(summary.names, ['Systolic BP']);
});

// Measured against OpenMRS FHIR2 4.2.0: two Condition resources per problem, one active and one
// unknown. An app that renders the bundle as-is shows every diagnosis twice.
test('problemList collapses the duplicate Conditions this server returns', () => {
	const condition = (id, code, display, status) => ({ resource: {
		resourceType: 'Condition', id,
		code: { coding: [{ code, display }] },
		clinicalStatus: { coding: [{ code: status }] },
	} });
	const list = problemList({ entry: [
		condition('1eea550a', '117399', 'Gonococcal arthritis', 'unknown'),
		condition('057e378b', '117399', 'Gonococcal arthritis', 'active'),
		condition('64616723', '145939', 'Hookworm disease', 'unknown'),
	] });

	assert.equal(list.length, 2);
	assert.equal(list.find((p) => p.name === 'Gonococcal arthritis').status, 'active');
	assert.equal(list.find((p) => p.name === 'Hookworm disease').status, 'unknown');
});

test('problemList keeps an onset date from whichever duplicate carries one', () => {
	const list = problemList({ entry: [
		{ resource: { resourceType: 'Condition', code: { coding: [{ code: '117399', display: 'X' }] },
			clinicalStatus: { coding: [{ code: 'active' }] } } },
		{ resource: { resourceType: 'Condition', code: { coding: [{ code: '117399', display: 'X' }] },
			clinicalStatus: { coding: [{ code: 'unknown' }] }, onsetDateTime: '2024-03-02' } },
	] });

	assert.equal(list.length, 1);
	assert.equal(list[0].status, 'active');
	assert.equal(list[0].onset, '2024-03-02');
});

test('problemList leaves a server that does not duplicate alone', () => {
	const list = problemList({ entry: [
		{ resource: { resourceType: 'Condition', code: { coding: [{ code: 'a', display: 'Asthma' }] },
			clinicalStatus: { coding: [{ code: 'active' }] } } },
		{ resource: { resourceType: 'Condition', code: { coding: [{ code: 'b', display: 'Anaemia' }] },
			clinicalStatus: { coding: [{ code: 'resolved' }] } } },
	] });

	assert.deepEqual(list.map((p) => p.name), ['Anaemia', 'Asthma']);
});
