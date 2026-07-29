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

    it('ships the icon it declares', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect(file_exists($this->pluginPath.'/'.$manifest['icon']))->toBeTrue();
    });

    it('declares every event class that exists', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        foreach (glob($this->pluginPath.'/src/Events/*.php') as $file) {
            $event = 'Vipertecpro\\WysiwygEditor\\Events\\'.basename($file, '.php');
            expect($manifest['events'])->toContain($event);
        }
    });
});

describe('Native parity', function () {
    /**
     * Both native files keep their OWN allow-list of tool names, because the
     * config arrives as untrusted JSON and has to be filtered somewhere. That
     * means three copies of the same list — and when `poll` and `divider` were
     * added to PHP alone, they silently vanished from both editors with no
     * error anywhere. These read the native sources and fail loudly instead.
     */
    it('lists the same tools natively as PHP does', function (string $file, string $pattern) {
        $source = file_get_contents($this->pluginPath.$file);

        expect(preg_match($pattern, $source, $m))->toBe(1);

        preg_match_all('/"([a-zA-Z0-9]+)"/', $m[1], $found);

        expect($found[1])->toBe(WysiwygEditor::AVAILABLE_TOOLS);
    })->with([
        ['/resources/ios/WysiwygEditorFunctions.swift', '/static let allTools = \[(.*?)\]/s'],
        ['/resources/android/WysiwygEditorFunctions.kt', '/val AVAILABLE_TOOLS = listOf\((.*?)\)/s'],
    ]);

    it('ships the same insert tools natively as PHP does', function (string $file, string $pattern) {
        $source = file_get_contents($this->pluginPath.$file);

        expect(preg_match($pattern, $source, $m))->toBe(1);

        preg_match_all('/"([a-zA-Z0-9]+)"/', $m[1], $found);

        expect($found[1])->toBe(WysiwygEditor::INSERT_TOOLS);
    })->with([
        ['/resources/ios/WysiwygEditorFunctions.swift', '/static let insertTools = \[(.*?)\]/s'],
        ['/resources/android/WysiwygEditorFunctions.kt', '/val INSERT_TOOLS = listOf\((.*?)\)/s'],
    ]);

    /**
     * A tool can be declared everywhere, labelled everywhere, pass every
     * parity check above — and still do NOTHING, because no dispatcher has a
     * case for it. That is exactly what happened to `poll`, `divider` and
     * `embed`: they worked from the Insert sheet and fell through the toolbar's
     * switch in silence. Nothing failed; the button just did not work.
     *
     * This reads the dispatchers and insists every tool is named in one.
     */
    it('handles every tool it offers, in a dispatcher that can act on it', function (string $file, array $functions) {
        $source = file_get_contents($this->pluginPath.$file);

        $handled = '';

        foreach ($functions as $pattern) {
            expect(preg_match($pattern, $source, $m))->toBe(1, "no dispatcher matched {$pattern}");
            $handled .= $m[1];
        }

        preg_match_all('/"([a-zA-Z0-9]+)"/', $handled, $found);

        $covered = $found[1];

        // A dispatcher may match against the shared insert list rather than
        // naming each one — that handles them just as well.
        if (str_contains($handled, 'INSERT_TOOLS') || str_contains($handled, 'insertTools')) {
            $covered = array_merge($covered, WysiwygEditor::INSERT_TOOLS);
        }

        $missing = array_values(array_diff(WysiwygEditor::AVAILABLE_TOOLS, $covered));

        expect($missing)->toBe([], 'tools with no handler: '.implode(', ', $missing));
    })->with([
        [
            '/resources/ios/WysiwygEditorFunctions.swift',
            [
                '/private func perform\(_ tool: String\) \{(.*?)\n    \}/s',
                '/private func apply\(_ tool: String, _ model: WysiwygEditorModel\) \{(.*?)\n    \}/s',
            ],
        ],
        [
            '/resources/android/WysiwygEditorFunctions.kt',
            ['/^private fun runTool\((.*?)\n\}/ms'],
        ],
    ]);

    it('labels tools with keys both platforms agree on', function (string $file, string $pattern) {
        $source = file_get_contents($this->pluginPath.$file);

        expect(preg_match($pattern, $source, $m))->toBe(1);

        preg_match_all('/"([a-zA-Z0-9]+)"\s*(?::|to)\s*"([a-zA-Z0-9]+)"/', $m[1], $found);

        expect(array_combine($found[1], $found[2]))->toBe(WysiwygEditor::TOOL_LABEL_KEYS);
    })->with([
        ['/resources/ios/WysiwygEditorFunctions.swift', '/let toolLabelKeys: \[String: String\] = \[(.*?)\n\]/s'],
        ['/resources/android/WysiwygEditorFunctions.kt', '/val TOOL_LABEL_KEYS = mapOf\((.*?)\n\)/s'],
    ]);
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

describe('Reopening a saved document', function () {
    it('passes HTML through as content', function () {
        $config = editor()->config('<p>Hi</p>');

        expect($config['content'])->toBe('<p>Hi</p>')
            ->and($config['contentJson'])->toBe('');
    });

    it('recognises our own JSON and hands it over intact', function () {
        $json = '{"version":2,"blocks":[{"id":"b1","type":"p","runs":[]}]}';
        $config = editor()->config($json);

        expect($config['contentJson'])->toBe($json)
            ->and($config['content'])->toBe('');
    });

    /**
     * The point of the whole feature: HTML cannot carry a device path, so a
     * post whose upload never finished loses its pictures on re-open unless
     * the JSON goes back in.
     */
    it('keeps a local path that HTML could never have carried', function () {
        $json = '{"version":2,"blocks":[{"id":"b1","type":"image","localPath":"/tmp/a.jpg"}]}';

        expect(editor()->config($json)['contentJson'])->toContain('/tmp/a.jpg');
    });

    it('treats anything that is not one of our documents as HTML', function (string $input) {
        $config = editor()->config($input);

        expect($config['content'])->toBe($input)
            ->and($config['contentJson'])->toBe('');
    })->with([
        '<p>{not json}</p>',
        '{"nope":1}',
        '{ broken',
        '',
        '   <p>leading space</p>',
    ]);
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

describe('Localization', function () {
    it('ships English defaults for every string', function () {
        $strings = editor()->config('')['strings'];

        expect($strings)->toBe(WysiwygEditor::STRINGS)
            ->and($strings['save'])->toBe('Save');
    });

    it('merges caller translations over the defaults', function () {
        $config = editor()->config('', ['strings' => ['save' => 'Guardar', 'cancel' => 'Cancelar']]);

        expect($config['strings']['save'])->toBe('Guardar')
            ->and($config['strings']['cancel'])->toBe('Cancelar')
            ->and($config['strings']['discard'])->toBe('Discard');
    });

    it('drops unknown keys so a typo cannot silently do nothing', function () {
        $config = editor()->config('', ['strings' => ['saev' => 'Guardar']]);

        expect($config['strings'])->not->toHaveKey('saev')
            ->and($config['strings']['save'])->toBe('Save');
    });

    it('keeps placeholders so translations control word order', function () {
        expect(WysiwygEditor::STRINGS['ruleMinWords'])->toContain('{n}')->toContain('{max}');
    });
});

describe('Composer presentation', function () {
    it('treats an explicit empty toolbar as none at all', function () {
        expect(editor()->config('', ['toolbar' => []])['toolbar'])->toBe([]);
    });

    it('still falls back when every requested tool is unknown', function () {
        expect(editor()->config('', ['toolbar' => ['nope']])['toolbar'])
            ->toBe(WysiwygEditor::TOOLBAR_PRESETS['full']);
    });

    it('defaults each presentation option to its first documented value', function () {
        $config = editor()->config('');

        expect($config['countStyle'])->toBe('text')
            ->and($config['maxLengthMode'])->toBe('hard')
            ->and($config['saveStyle'])->toBe('text');
    });

    it('accepts the documented values', function () {
        $config = editor()->config('', [
            'countStyle' => 'ring',
            'maxLengthMode' => 'soft',
            'saveStyle' => 'filled',
        ]);

        expect($config['countStyle'])->toBe('ring')
            ->and($config['maxLengthMode'])->toBe('soft')
            ->and($config['saveStyle'])->toBe('filled');
    });

    it('shows undo and redo unless asked not to', function () {
        expect(editor()->config('')['history'])->toBeTrue()
            ->and(editor()->config('', ['history' => false])['history'])->toBeFalse();
    });

    it('falls back for anything unrecognised', function (string $key) {
        expect(editor()->config('', [$key => 'nonsense'])[$key])->toBeIn(['text', 'hard']);
    })->with(['countStyle', 'maxLengthMode', 'saveStyle']);
});

describe('Media layout and cap', function () {
    it('keeps media in the document flow by default', function () {
        expect(editor()->config('')['mediaLayout'])->toBe('blocks');
    });

    it('accepts the strip used by social composers', function () {
        expect(editor()->config('', ['mediaLayout' => 'strip'])['mediaLayout'])->toBe('strip');
    });

    it('caps media at four, which is what the grids are built for', function () {
        expect(editor()->config('')['maxMedia'])->toBe(4)
            ->and(WysiwygEditor::DEFAULT_MAX_MEDIA)->toBe(4);
    });

    it('lets the host raise, lower or lift the cap', function () {
        expect(editor()->config('', ['maxMedia' => 10])['maxMedia'])->toBe(10)
            ->and(editor()->config('', ['maxMedia' => 1])['maxMedia'])->toBe(1)
            ->and(editor()->config('', ['maxMedia' => 0])['maxMedia'])->toBe(0)
            ->and(editor()->config('', ['maxMedia' => -3])['maxMedia'])->toBe(0);
    });
});

describe('Polls', function () {
    it('caps an option at a length someone can read at a glance', function () {
        expect(editor()->config('')['pollOptionMaxLength'])->toBe(25)
            ->and(editor()->config('', ['pollOptionMaxLength' => 40])['pollOptionMaxLength'])->toBe(40)
            ->and(editor()->config('', ['pollOptionMaxLength' => 0])['pollOptionMaxLength'])->toBe(1);
    });

    it('needs at least two answers and stops at a handful', function () {
        $config = editor()->config('');

        expect($config['pollMinOptions'])->toBe(2)
            ->and($config['pollMaxOptions'])->toBe(4);
    });

    it('offers durations in minutes, because the editor owns no clock', function () {
        $durations = editor()->config('')['pollDurations'];

        expect($durations)->toBe(['pollDay1' => 1440, 'pollDays3' => 4320, 'pollDays7' => 10080]);

        // Every duration must be labelled, or the picker shows a raw key.
        foreach (array_keys($durations) as $key) {
            expect(WysiwygEditor::STRINGS)->toHaveKey($key);
        }
    });
});

describe('Host accessory rows', function () {
    it('has none unless the host asks for them', function () {
        expect(editor()->config('')['accessories'])->toBe([]);
    });

    it('carries id, label, icon and value through in order', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'tag', 'label' => 'Tag people', 'icon' => 'image'],
            ['id' => 'audience', 'label' => 'Everyone can reply', 'value' => 'Everyone'],
        ]]);

        expect($config['accessories'])->toBe([
            ['id' => 'tag', 'label' => 'Tag people', 'icon' => 'image'],
            ['id' => 'audience', 'label' => 'Everyone can reply', 'value' => 'Everyone'],
        ]);
    });

    /**
     * A row with no id could never report a tap, and one with no label would
     * draw as a blank tappable strip. Both are dropped rather than shown.
     */
    it('drops rows that could not work', function (array $row) {
        expect(editor()->config('', ['accessories' => [$row]])['accessories'])->toBe([]);
    })->with([
        [['label' => 'No id']],
        [['id' => 'no-label']],
        [['id' => '  ', 'label' => 'blank id']],
        [['id' => 'blank-label', 'label' => '   ']],
    ]);

    it('ignores keys it does not know', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'a', 'label' => 'A', 'onTap' => 'doSomething()'],
        ]]);

        expect($config['accessories'][0])->toBe(['id' => 'a', 'label' => 'A']);
    });
});

describe('Menu mode', function () {
    it('defaults to the scrolling toolbar', function () {
        expect(editor()->config('')['menu'])->toBe('toolbar');
    });

    it('accepts the documented modes', function (string $mode) {
        expect(editor()->config('', ['menu' => $mode])['menu'])->toBe($mode);
    })->with(WysiwygEditor::MENU_MODES);

    it('falls back to the toolbar for anything unrecognised', function () {
        expect(editor()->config('', ['menu' => 'popover'])['menu'])->toBe('toolbar');
    });

    it('labels every tool a sheet can show, with a string that exists', function () {
        foreach (WysiwygEditor::AVAILABLE_TOOLS as $tool) {
            expect(WysiwygEditor::TOOL_LABEL_KEYS)->toHaveKey($tool);
            expect(WysiwygEditor::STRINGS)->toHaveKey(WysiwygEditor::TOOL_LABEL_KEYS[$tool]);
        }
    });

    it('does not label tools that do not exist', function () {
        expect(array_diff(array_keys(WysiwygEditor::TOOL_LABEL_KEYS), WysiwygEditor::AVAILABLE_TOOLS))
            ->toBe([]);
    });
});

describe('Typography', function () {
    it('defaults to the system font and the existing ramp base', function () {
        $t = editor()->config('')['typography'];

        expect($t['fontFamily'])->toBe('')
            ->and($t['fontSize'])->toBe(16)
            ->and($t['lineHeight'])->toBe(1.15);
    });

    it('carries an explicit family, size and line height', function () {
        $t = editor()->config('', ['typography' => [
            'fontFamily' => 'Inter',
            'fontSize' => 18,
            'lineHeight' => 1.4,
        ]])['typography'];

        expect($t['fontFamily'])->toBe('Inter')
            ->and($t['fontSize'])->toBe(18)
            ->and($t['lineHeight'])->toBe(1.4);
    });

    it('clamps sizes a text engine cannot lay out sensibly', function () {
        expect(editor()->config('', ['typography' => ['fontSize' => 200]])['typography']['fontSize'])->toBe(32)
            ->and(editor()->config('', ['typography' => ['fontSize' => 2]])['typography']['fontSize'])->toBe(10)
            ->and(editor()->config('', ['typography' => ['lineHeight' => 9]])['typography']['lineHeight'])->toBe(2.0);
    });

    it('adopts the host application font when the caller names none', function () {
        \Nativephp\NativeUi\Theme::load(['fonts' => ['default' => 'Sora']]);

        expect(editor()->config('')['typography']['fontFamily'])->toBe('Sora');

        \Nativephp\NativeUi\Theme::reset();
    });

    it('lets an explicit family win over the host font', function () {
        \Nativephp\NativeUi\Theme::load(['fonts' => ['default' => 'Sora']]);

        expect(editor()->config('', ['typography' => ['fontFamily' => 'Inter']])['typography']['fontFamily'])
            ->toBe('Inter');

        \Nativephp\NativeUi\Theme::reset();
    });
});

describe('Spacing', function () {
    it('defaults to the density the editor already had', function () {
        expect(editor()->config('')['spacing'])->toBe('comfortable');
    });

    it('accepts the documented scales', function (string $scale) {
        expect(editor()->config('', ['spacing' => $scale])['spacing'])->toBe($scale);
    })->with(array_keys(WysiwygEditor::SPACING_SCALES));

    it('falls back for anything unrecognised', function () {
        expect(editor()->config('', ['spacing' => 'airy'])['spacing'])->toBe('comfortable');
    });

    it('describes every scale with the same three measurements', function () {
        foreach (WysiwygEditor::SPACING_SCALES as $scale) {
            expect(array_keys($scale))->toBe(['horizontal', 'vertical', 'paragraph']);
        }
    });
});

describe('Validation rules', function () {
    it('is empty by default', function () {
        expect(editor()->config('')['validation'])->toBe([]);
    });

    it('keeps known rules and coerces them', function () {
        $config = editor()->config('', ['validation' => [
            'minWords' => '50',
            'requiredBlocks' => ['image', 42],
            'nope' => 1,
        ]]);

        expect($config['validation'])->toBe([
            'minWords' => 50,
            'requiredBlocks' => ['image'],
        ]);
    });
});

describe('Auto-save seam', function () {
    it('is off by default so apps that do not want it pay nothing', function () {
        expect(editor()->config('')['changeDebounce'])->toBe(0);
    });

    it('carries the debounce and clamps negatives', function () {
        expect(editor()->config('', ['changeDebounce' => 1500])['changeDebounce'])->toBe(1500)
            ->and(editor()->config('', ['changeDebounce' => -5])['changeDebounce'])->toBe(0);
    });

    it('enables haptics unless turned off', function () {
        expect(editor()->config('')['haptics'])->toBeTrue()
            ->and(editor()->config('', ['haptics' => false])['haptics'])->toBeFalse();
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
            'highlight' => '#0000FF',
        ]);

        // Dark has no `background`/`on-background`; the fallbacks are used.
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
