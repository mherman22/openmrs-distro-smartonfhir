// Small SVG line charts, drawn by hand.
//
// No charting library and no CDN: this app has to run in a browser that cannot reach the internet,
// against a server on localhost, and a strict page that loads nothing remote is easier to trust than
// one that pulls a bundle from elsewhere.

const W = 520, H = 130, PAD = { top: 12, right: 12, bottom: 22, left: 40 };

const escapeHtml = (t) => String(t).replace(/[&<>"']/g,
	(c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/**
 * Draws one series, optionally with a shaded reference band and a highlighted point.
 *
 * A single-point series is drawn as a dot rather than skipped: one reading is real data, and omitting
 * the chart would suggest there was none.
 */
export function lineChart({ points, unit, band, highlightAt, label }) {
	if (!points || points.length === 0) return '<p class="empty">Not recorded</p>';

	const values = points.map((p) => p.value);
	const lo = Math.min(...values, band?.low ?? Infinity);
	const hi = Math.max(...values, band?.high ?? -Infinity);
	const pad = (hi - lo) * 0.15 || 1;
	const min = lo - pad, max = hi + pad;

	const times = points.map((p) => new Date(p.at).getTime());
	const t0 = Math.min(...times), t1 = Math.max(...times);

	const x = (t) => PAD.left + (t1 === t0 ? (W - PAD.left - PAD.right) / 2
		: ((t - t0) / (t1 - t0)) * (W - PAD.left - PAD.right));
	const y = (v) => PAD.top + (1 - (v - min) / (max - min)) * (H - PAD.top - PAD.bottom);

	const coords = points.map((p, i) => [x(times[i]), y(p.value), p]);
	const path = coords.map(([px, py], i) => `${i === 0 ? 'M' : 'L'}${px.toFixed(1)},${py.toFixed(1)}`).join(' ');

	const bandRect = band
		? `<rect class="band" x="${PAD.left}" y="${y(band.high).toFixed(1)}" width="${W - PAD.left - PAD.right}" `
		  + `height="${Math.max(0, y(band.low) - y(band.high)).toFixed(1)}"></rect>`
		: '';

	const dots = coords.map(([px, py, p]) => {
		const on = highlightAt && p.at.slice(0, 10) === highlightAt.slice(0, 10);
		return `<circle class="dot${on ? ' dot-on' : ''}" cx="${px.toFixed(1)}" cy="${py.toFixed(1)}" r="${on ? 5 : 3}">`
			+ `<title>${escapeHtml(p.value)} ${escapeHtml(unit)} — ${escapeHtml(p.at.slice(0, 10))}</title></circle>`;
	}).join('');

	const year = (t) => new Date(t).getFullYear();

	return `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img"
	  aria-label="${escapeHtml(label)}: ${points.length} readings from ${escapeHtml(points[0].at.slice(0, 10))} to ${escapeHtml(points[points.length - 1].at.slice(0, 10))}">
	  ${bandRect}
	  <line class="axis" x1="${PAD.left}" y1="${H - PAD.bottom}" x2="${W - PAD.right}" y2="${H - PAD.bottom}"></line>
	  <text class="tick" x="4" y="${(PAD.top + 4).toFixed(1)}">${max.toFixed(0)}</text>
	  <text class="tick" x="4" y="${(H - PAD.bottom).toFixed(1)}">${min.toFixed(0)}</text>
	  <text class="tick" x="${PAD.left}" y="${H - 6}">${year(t0)}</text>
	  <text class="tick end" x="${W - PAD.right}" y="${H - 6}">${year(t1)}</text>
	  ${points.length > 1 ? `<path class="line" d="${path}"></path>` : ''}
	  ${dots}
	</svg>`;
}
