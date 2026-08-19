import FHIR from 'fhirclient';

/**
 * The launch entry point. The EHR sends the browser here with `iss` and `launch`; fhirclient reads
 * both, fetches the server's .well-known/smart-configuration, and redirects to the authorization
 * endpoint. Nothing about this file is OpenMRS-specific, which is the point of the standard.
 *
 * `completeInTarget` is set because an EHR launch may open this in a new tab: without it the library
 * tries to finish the handshake in the opener and the app never receives its token.
 */
FHIR.oauth2.authorize({
	clientId: new URLSearchParams(location.search).get('client_id') ?? 'smartClient',
	// Only what this app reads. Asking for more would be refused by a server that enforces scopes, and
	// on one that does not it would take privileges this app has no use for.
	scope: 'launch openid fhirUser patient/Patient.rs patient/Observation.rs patient/Condition.rs patient/Encounter.rs',
	redirectUri: 'index.html',
	completeInTarget: true,
	pkceMode: 'required',
}).catch((error) => {
	document.body.innerHTML =
		`<main class="failure"><h1>Launch failed</h1><p>${escapeHtml(String(error?.message ?? error))}</p></main>`;
});

function escapeHtml(text) {
	return text.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
