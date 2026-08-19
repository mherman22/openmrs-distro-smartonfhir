import FHIR from 'fhirclient';
import { VITALS, ageYears, bmiCategory } from './vitals.js';
import { toSeries, bmiSeries, latest, summarise, problemList } from './series.js';
import { lineChart } from './chart.js';

const REFERENCE_BANDS = {
	systolic: { low: 90, high: 120 },
	diastolic: { low: 60, high: 80 },
	pulse: { low: 60, high: 100 },
	temperature: { low: 36.1, high: 37.5 },
	spo2: { low: 95, high: 100 },
	respiratory: { low: 12, high: 20 },
};

const esc = (t) => String(t ?? '').replace(/[&<>"']/g,
	(c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const el = (id) => document.getElementById(id);

/**
 * Reads everything within this app's scopes, then renders.
 *
 * Requests run in parallel and each is allowed to fail on its own: a server that serves Observations
 * but refuses Conditions should still produce a vitals review rather than an error page.
 */
async function main() {
	const client = await FHIR.oauth2.ready();

	const patientId = client.patient.id;
	if (!patientId) throw new Error('The launch carried no patient. This app cannot run without one.');

	const [patient, observations, conditions, encounters] = await Promise.all([
		client.patient.read(),
		client.request(`Observation?patient=${patientId}&_count=500`, { flat: false }).catch(() => null),
		client.request(`Condition?patient=${patientId}&_count=100`, { flat: false }).catch(() => null),
		client.request(`Encounter?patient=${patientId}&_count=100`, { flat: false }).catch(() => null),
	]);

	// The encounter the EHR launched for, when it launched for one. This is the difference between a
	// patient launch and an encounter launch, and the only place the app treats them differently.
	const launchedEncounter = client.encounter?.id ?? null;

	render({ client, patient, observations, conditions, encounters, launchedEncounter });
}

function render({ patient, observations, conditions, encounters, launchedEncounter }) {
	const age = ageYears(patient.birthDate);
	const series = toSeries(observations);
	const rows = latest(series, age);
	const summary = summarise(rows);
	const bmis = bmiSeries(series);

	const visits = (encounters?.entry ?? [])
		.map((e) => e.resource)
		.filter((r) => r?.resourceType === 'Encounter')
		.sort((a, b) => String(b.period?.start ?? '').localeCompare(String(a.period?.start ?? '')));

	const launched = visits.find((v) => v.id === launchedEncounter) ?? null;
	const highlightAt = launched?.period?.start ?? null;

	// Whether any series has a reading on the launched visit's day. Without this the banner promised
	// ringed readings for a visit that recorded none, which is a claim the page then failed to keep.
	const ringed = highlightAt != null && [...series.values()]
		.some((points) => points.some((p) => p.at.slice(0, 10) === highlightAt.slice(0, 10)));

	el('app').innerHTML = `
		${header(patient, age, visits.length)}
		${banner(summary, rows, launched, ringed)}
		${bmiCard(bmis)}
		${vitalsGrid(series, rows, highlightAt)}
		${problems(conditions)}
		${timeline(visits, launchedEncounter)}
	`;
	el('loading')?.remove();
}

function header(patient, age, visitCount) {
	const name = patient.name?.[0];
	const display = [name?.given?.join(' '), name?.family].filter(Boolean).join(' ') || '(unnamed)';
	const mrn = patient.identifier?.find((i) => i.value)?.value;

	return `<header>
		<h1>${esc(display)}</h1>
		<p class="meta">
			${age != null ? `${age} years` : 'age unknown'} ·
			${esc(patient.gender ?? 'gender unknown')} ·
			${mrn ? `MRN ${esc(mrn)} · ` : ''}${visitCount} recorded visit${visitCount === 1 ? '' : 's'}
		</p>
	</header>`;
}

/** The line a clinician reads first, and the one thing this app exists to say. */
function banner(summary, rows, launched, ringed) {
	const outside = rows.filter((r) => r.reading.status !== 'normal' && r.reading.status !== 'unknown');
	const tone = summary.outside === 0 ? 'ok' : summary.outside > 2 ? 'alert' : 'warn';

	const detail = outside.length
		? outside.map((r) => `<li><b>${esc(r.label)}</b> ${esc(r.value)} ${esc(r.unit)}`
			+ `${r.reading.label ? ` — ${esc(r.reading.label)}` : ` — ${esc(r.reading.status)}`}</li>`).join('')
		: '<li>Every vital with an applicable reference range is within it.</li>';

	const visitDay = esc((launched?.period?.start ?? '').slice(0, 10));
	const context = launched
		? `<p class="context">Launched for the visit of <b>${visitDay}</b>${ringed
			? '; its readings are ringed below.'
			: ', which recorded no vitals of its own — the trends below are the whole record.'}</p>`
		: '';

	return `<section class="banner ${tone}">
		<h2>${summary.outside} of ${summary.assessable} latest vitals outside range</h2>
		<ul>${detail}</ul>
		${summary.assessable < rows.length
			? `<p class="note">${rows.length - summary.assessable} recorded vital${rows.length - summary.assessable === 1 ? '' : 's'}
				 have no adult reference range here and are shown without a verdict.</p>`
			: ''}
		${context}
	</section>`;
}

/**
 * BMI is the clearest demonstration that this is an application rather than a viewer: OpenMRS stores
 * height and weight and no BMI, so every number in this card was computed here.
 */
function bmiCard(points) {
	if (points.length === 0) {
		return `<section class="card"><h3>Body mass index</h3>
			<p class="empty">Needs a height and a weight recorded on the same day. None found.</p></section>`;
	}

	const current = points[points.length - 1];
	const first = points[0];
	const change = Math.round((current.value - first.value) * 10) / 10;

	return `<section class="card">
		<h3>Body mass index <span class="derived">derived</span></h3>
		<p class="big">${current.value} <span class="unit">kg/m²</span>
			<span class="cat cat-${current.category.replace(/\s/g, '-')}">${esc(current.category)}</span></p>
		<p class="meta">${points.length} paired measurement${points.length === 1 ? '' : 's'}
			${points.length > 1 ? `· ${change >= 0 ? '+' : ''}${change} since ${esc(first.at.slice(0, 10))}` : ''}
			· not stored by the server, computed from height and weight</p>
		${lineChart({ points, unit: 'kg/m²', band: { low: 18.5, high: 25 }, label: 'Body mass index' })}
	</section>`;
}

function vitalsGrid(series, rows, highlightAt) {
	const byKey = new Map(rows.map((r) => [r.key, r]));

	const cards = VITALS.map((vital) => {
		const points = series.get(vital.key) ?? [];
		const row = byKey.get(vital.key);
		const status = row?.reading.status ?? 'unknown';

		return `<section class="card status-${status}">
			<h3>${esc(vital.label)}</h3>
			${row ? `<p class="big">${esc(row.value)} <span class="unit">${esc(vital.unit)}</span>
				${row.reading.label ? `<span class="flag">${esc(row.reading.label)}</span>`
					: status !== 'normal' && status !== 'unknown' ? `<span class="flag">${esc(status)}</span>` : ''}
				${row.delta != null ? `<span class="delta">${row.delta >= 0 ? '+' : ''}${esc(row.delta)}</span>` : ''}</p>
				<p class="meta">last recorded ${esc(row.at.slice(0, 10))}</p>` : ''}
			${lineChart({ points, unit: vital.unit, band: REFERENCE_BANDS[vital.key], highlightAt, label: vital.label })}
		</section>`;
	}).join('');

	return `<div class="grid">${cards}</div>`;
}

function problems(conditions) {
	const list = problemList(conditions);
	const returned = (conditions?.entry ?? []).filter((e) => e.resource?.resourceType === 'Condition').length;

	if (list.length === 0) {
		return `<section class="card"><h3>Problem list</h3><p class="empty">No conditions recorded.</p></section>`;
	}

	const items = list.map((p) => `<li><b>${esc(p.name)}</b>`
		+ `${p.onset ? ` <span class="meta">onset ${esc(p.onset.slice(0, 10))}</span>` : ''}`
		+ `${p.status && p.status !== 'unknown' ? ` <span class="pill">${esc(p.status)}</span>` : ''}</li>`).join('');

	return `<section class="card"><h3>Problem list <span class="meta">${list.length}</span></h3>
		<ul class="problems">${items}</ul>
		${returned > list.length
			? `<p class="note">${returned} Condition resources collapsed to ${list.length} problems — this
				 server returns one per clinical status.</p>`
			: ''}</section>`;
}

function timeline(visits, launchedId) {
	if (visits.length === 0) return '';

	const items = visits.slice(0, 12).map((v) => {
		const start = (v.period?.start ?? '').slice(0, 10);
		const type = v.type?.[0]?.coding?.find((c) => c.display)?.display ?? v.class?.display ?? 'Visit';
		const on = v.id === launchedId;
		return `<li class="${on ? 'on' : ''}"><span class="when">${esc(start)}</span> ${esc(type)}
			${on ? '<span class="pill">launched for this visit</span>' : ''}</li>`;
	}).join('');

	return `<section class="card"><h3>Visits <span class="meta">${visits.length}</span></h3>
		<ol class="timeline">${items}</ol></section>`;
}

main().catch((error) => {
	el('app').innerHTML = `<section class="banner alert"><h2>Could not load this patient</h2>
		<p>${esc(error?.message ?? error)}</p></section>`;
	el('loading')?.remove();
});
