<?php

use Vipertecpro\WysiwygEditor\WysiwygEditor;

/**
 * Plugin validation tests for WysiwygEditor.
 *
 * Run with: ./vendor/bin/pest
 */
beforeEach(function () {
    $this->pluginPath = dirname(__DIR__);
    $this->manifestPath = $this->pluginPath.'/nativephp.json';
});

/**
 * Test double exposing the protected config resolvers.
 */
function editor(): WysiwygEditor
{
    return new class extends WysiwygEditor
    {
        /** @return array<string, mixed> */
        public function config(string $html, array $options = []): array
        {
            return $this->resolveConfig($html, $options);
        }
    };
}

describe('Plugin Manifest', function () {
    it('has a valid nativephp.json file', function () {
        expect(file_exists($this->manifestPath))->toBeTrue();

        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect(json_last_error())->toBe(JSON_ERROR_NONE);
    });

    it('has required fields', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest)->toHaveKeys(['name', 'namespace', 'bridge_functions']);
        expect($manifest['name'])->toBe('vipertecpro/wysiwyg-editor');
        expect($manifest['namespace'])->toBe('WysiwygEditor');
    });

    it('has valid bridge functions', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest['bridge_functions'])->toBeArray();

        foreach ($manifest['bridge_functions'] as $function) {
            expect($function)->toHaveKeys(['name']);
            expect(isset($function['android']) || isset($function['ios']))->toBeTrue();
        }
    });

    it('declares both result events', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect($manifest['events'])->toContain('Vipertecpro\WysiwygEditor\Events\ContentSaved');
        expect($manifest['events'])->toContain('Vipertecpro\WysiwygEditor\Events\EditCancelled');
    });

    it('points to native sources that exist', function () {
        expect(file_exists($this->pluginPath.'/resources/ios/WysiwygEditorFunctions.swift'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/android/WysiwygEditorFunctions.kt'))->toBeTrue();
    });
});

describe('Toolbar resolution', function () {
    it('defaults to the full toolbar', function () {
        $config = editor()->config('');

        expect($config['toolbar'])->toBe(WysiwygEditor::TOOLBAR_PRESETS['full']);
    });

    it('resolves toolbar presets', function (string $preset) {
        $config = editor()->config('', ['preset' => $preset]);

        expect($config['toolbar'])->toBe(WysiwygEditor::TOOLBAR_PRESETS[$preset]);
    })->with(array_keys(WysiwygEditor::TOOLBAR_PRESETS));

    it('falls back to the full toolbar for an unknown preset', function () {
        $config = editor()->config('', ['preset' => 'nope']);

        expect($config['toolbar'])->toBe(WysiwygEditor::TOOLBAR_PRESETS['full']);
    });

    it('lets an explicit toolbar override the preset and keeps its order', function () {
        $config = editor()->config('', [
            'preset' => 'comment',
            'toolbar' => ['link', 'bold', 'h2'],
        ]);

        expect($config['toolbar'])->toBe(['link', 'bold', 'h2']);
    });

    it('drops unknown tools and duplicates', function () {
        $config = editor()->config('', ['toolbar' => ['bold', 'sparkles', 'bold', 'italic']]);

        expect($config['toolbar'])->toBe(['bold', 'italic']);
    });

    it('falls back to the full toolbar when every requested tool is unknown', function () {
        $config = editor()->config('', ['toolbar' => ['sparkles', 'kitchenSink']]);

        expect($config['toolbar'])->toBe(WysiwygEditor::TOOLBAR_PRESETS['full']);
    });

    it('only presets tools that actually exist', function () {
        foreach (WysiwygEditor::TOOLBAR_PRESETS as $tools) {
            expect(array_diff($tools, WysiwygEditor::AVAILABLE_TOOLS))->toBe([]);
        }
    });
});

describe('Config resolution', function () {
    it('passes content through untouched', function () {
        $html = '<p>Hello <strong>world</strong></p>';

        expect(editor()->config($html)['content'])->toBe($html);
    });

    it('applies defaults', function () {
        $config = editor()->config('');

        expect($config['title'])->toBe('')
            ->and($config['placeholder'])->toBe('')
            ->and($config['maxLength'])->toBe(0)
            ->and($config['theme'])->toBe([])
            ->and($config['id'])->toBeNull();
    });

    it('carries title, placeholder, maxLength and id', function () {
        $config = editor()->config('', [
            'title' => 'Edit note',
            'placeholder' => 'Write…',
            'maxLength' => 500,
            'id' => 'note-42',
        ]);

        expect($config['title'])->toBe('Edit note')
            ->and($config['placeholder'])->toBe('Write…')
            ->and($config['maxLength'])->toBe(500)
            ->and($config['id'])->toBe('note-42');
    });

    it('clamps a negative maxLength to unlimited', function () {
        expect(editor()->config('', ['maxLength' => -5])['maxLength'])->toBe(0);
    });
});

describe('Counts', function () {
    it('is off by default', function () {
        expect(editor()->config('')['counts'])->toBe([]);
    });

    it('keeps known readouts in the documented order', function () {
        $config = editor()->config('', ['counts' => ['words', 'characters']]);

        expect($config['counts'])->toBe(['characters', 'words']);
    });

    it('drops unknown readouts', function () {
        expect(editor()->config('', ['counts' => ['sentences']])['counts'])->toBe([]);
    });
});

describe('Host theme adoption', function () {
    it('emits a palette per colour scheme', function () {
        $config = editor()->config('');

        expect($config)->toHaveKeys(['themeLight', 'themeDark']);
    });

    it('derives the editor palette from the host tokens', function () {
        \Nativephp\NativeUi\Theme::load([
            'light' => [
                'background' => '#FFFFFF',
                'on-background' => '#111111',
                'primary' => '#0000FF',
                'accent' => '#FF00FF',
            ],
            'dark' => [
                'surface' => '#000000',
                'on-surface' => '#EEEEEE',
                'primary' => '#00FFFF',
            ],
        ]);

        $config = editor()->config('');

        expect($config['themeLight'])->toBe([
            'background' => '#FFFFFF',
            'text' => '#111111',
            'accent' => '#0000FF',
            'highlight' => '#FF00FF',
        ]);

        // Dark has no `background`/`on-background`; the fallbacks are used,
        // and `highlight` falls all the way back to `primary`.
        expect($config['themeDark'])->toBe([
            'background' => '#000000',
            'text' => '#EEEEEE',
            'accent' => '#00FFFF',
            'highlight' => '#00FFFF',
        ]);

        \Nativephp\NativeUi\Theme::reset();
    });

    it('stays empty when the host has no tokens, so native defaults apply', function () {
        \Nativephp\NativeUi\Theme::reset();

        $config = editor()->config('');

        expect($config['themeLight'])->toBe([])
            ->and($config['themeDark'])->toBe([]);
    });

    it('ignores malformed host colours rather than passing them through', function () {
        \Nativephp\NativeUi\Theme::load(['light' => ['background' => 'rebeccapurple']]);

        expect(editor()->config('')['themeLight'])->toBe([]);

        \Nativephp\NativeUi\Theme::reset();
    });
});

describe('Theme resolution', function () {
    it('keeps valid hex colors and normalises the leading hash', function () {
        $config = editor()->config('', ['theme' => [
            'background' => '121417',
            'text' => '#FFF',
            'accent' => '#F97316',
            'highlight' => '#22C55E80',
        ]]);

        expect($config['theme'])->toBe([
            'background' => '#121417',
            'text' => '#FFF',
            'accent' => '#F97316',
            'highlight' => '#22C55E80',
        ]);
    });

    it('drops unknown keys and malformed colors', function () {
        $config = editor()->config('', ['theme' => [
            'background' => 'red',
            'border' => '#FFFFFF',
            'accent' => '#GG0000',
        ]]);

        expect($config['theme'])->toBe([]);
    });
});
