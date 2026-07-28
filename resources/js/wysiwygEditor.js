/**
 * WysiwygEditor Plugin for NativePHP Mobile — JavaScript bridge (legacy web-view apps).
 *
 * NOTE: the primary consumer in v4 is a SuperNative `NativeComponent` calling the
 * PHP facade (`WysiwygEditor::open(...)`) and handling the `ContentSaved` /
 * `EditCancelled` events with `#[On]`. This JS wrapper is provided for
 * Livewire/Inertia web-view screens. Because the result is delivered
 * asynchronously via a native event (not the call's return value), subscribe to
 * the events with the `#nativephp` `On()` helper.
 *
 * @example
 *   import { wysiwygEditor } from '@vipertecpro/wysiwyg-editor';
 *   import { On } from '#nativephp';
 *
 *   On('native:Vipertecpro\\WysiwygEditor\\Events\\ContentSaved', ({ html, text }) => {
 *       // use the edited HTML
 *   });
 *
 *   await wysiwygEditor.open('<p>Hello</p>', { title: 'Edit note', maxLength: 500 });
 */

const baseUrl = '/_native/api/call';

/**
 * Internal bridge call function.
 * @private
 */
async function bridgeCall(method, params = {}) {
    const response = await fetch(baseUrl, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'X-CSRF-TOKEN': document.querySelector('meta[name="csrf-token"]')?.content || ''
        },
        body: JSON.stringify({ method, params })
    });

    const result = await response.json();

    if (result.status === 'error') {
        throw new Error(result.message || 'Native call failed');
    }

    return result.data;
}

/**
 * Open the full-screen native rich text editor.
 *
 * The result is NOT returned here — listen for the `ContentSaved` /
 * `EditCancelled` native events instead (see the module example above).
 *
 * @param {string} [html] - The current content as HTML.
 * @param {Object} [options]
 * @param {string[]} [options.toolbar] - Ordered tool list (see the README for keys).
 * @param {string} [options.title] - Top-bar heading.
 * @param {string} [options.placeholder] - Shown while the editor is empty.
 * @param {number} [options.maxLength=0] - Max plain-text length; 0 = unlimited.
 * @param {Object} [options.theme] - Hex colors: background, text, accent, highlight.
 * @param {string} [options.id] - Optional correlation id echoed back on the event.
 * @returns {Promise<void>}
 */
export async function open(html = '', options = {}) {
    return bridgeCall('WysiwygEditor.Open', {
        content: html,
        toolbar: options.toolbar ?? [],
        title: options.title ?? '',
        placeholder: options.placeholder ?? '',
        maxLength: options.maxLength ?? 0,
        theme: options.theme ?? {},
        id: options.id ?? null
    });
}

/**
 * WysiwygEditor namespace object.
 */
export const wysiwygEditor = { open };

export default wysiwygEditor;
