<?php

use Nativephp\NativeUi\Theme;
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
/**
 * Both native sources, keyed by platform.
 *
 * Every key of the config exists three times — once in PHP and once in each
 * native file — because the config arrives as untrusted JSON and has to be
 * filtered somewhere. Nothing but a test keeps the three in step.
 *
 * @return array<string, string>
 */
function nativeSources(): array
{
    return [
        'iOS' => file_get_contents(__DIR__.'/../resources/ios/WysiwygEditorFunctions.swift'),
        'Android' => file_get_contents(__DIR__.'/../resources/android/WysiwygEditorFunctions.kt'),
    ];
}

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

    /**
     * A bridge function declared in the manifest is CODE-GENERATED into each
     * platform's registration file, so declaring one without implementing it
     * does not fail gracefully — it stops the whole app compiling.
     *
     * Adding Preview and SetAccessory broke the Android build entirely, and it
     * went unnoticed because compiling the plugin file alone still succeeded;
     * only the generated registration referenced the missing classes.
     */
    it('implements every bridge function it declares, on both platforms', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        $ios = file_get_contents($this->pluginPath.'/resources/ios/WysiwygEditorFunctions.swift');
        $android = file_get_contents($this->pluginPath.'/resources/android/WysiwygEditorFunctions.kt');

        foreach ($manifest['bridge_functions'] as $function) {
            // "WysiwygEditor.Open" -> "Open"
            $name = substr($function['name'], strrpos($function['name'], '.') + 1);

            expect(preg_match('/class '.$name.'\b/', $ios))
                ->toBe(1, "iOS has no {$name} bridge function");
            expect(preg_match('/class '.$name.'\b/', $android))
                ->toBe(1, "Android has no {$name} bridge function");
        }
    });

    it('points to native sources that exist', function () {
        expect(file_exists($this->pluginPath.'/resources/ios/WysiwygEditorFunctions.swift'))->toBeTrue();
        expect(file_exists($this->pluginPath.'/resources/android/WysiwygEditorFunctions.kt'))->toBeTrue();
    });

    it('ships the icon it declares', function () {
        $manifest = json_decode(file_get_contents($this->manifestPath), true);

        expect(file_exists($this->pluginPath.'/'.$manifest['icon']))->toBeTrue();
    });

    /**
     * `#[On(SomeEvent::class)]` does NOT autoload the class, so a listener for
     * an event whose base class does not exist registers happily and then
     * fails in SILENCE when the event is finally constructed. AccessoryTapped
     * did exactly that: it extended a base that was never there, so tapping
     * the row did nothing and nothing was logged.
     *
     * This suite has no Laravel to construct against — which is why the gap
     * existed — so the convention is checked at the source level here, and the
     * demo app constructs them for real.
     */
    it('builds every event the same way as the ones that work', function () {
        foreach (glob($this->pluginPath.'/src/Events/*.php') as $file) {
            $source = file_get_contents($file);
            $name = basename($file, '.php');

            // toContain takes NEEDLES, not a message — passing one as a second
            // argument silently asserts the message itself is in the file.
            expect($source)->toContain('use Illuminate\\Foundation\\Events\\Dispatchable;')
                ->and($source)->toContain('use Illuminate\\Queue\\SerializesModels;')
                ->and($source)->toContain('use Dispatchable, SerializesModels;');

            // Extending anything is how the broken one broke.
            expect(preg_match('/class '.$name.'\s+extends/', $source))
                ->toBe(0, "{$name} extends a base class");
        }
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
    /**
     * The glyph tables are two hand-written copies of the same drawings. A
     * name present in one and not the other draws a blank gap on that platform
     * and nowhere else — the kind of thing nobody notices until a user does.
     */
    it('draws the same set of glyphs on both platforms', function () {
        $swift = file_get_contents(__DIR__.'/../resources/ios/WysiwygEditorFunctions.swift');
        $kotlin = file_get_contents(__DIR__.'/../resources/android/WysiwygEditorFunctions.kt');

        preg_match_all('/"([a-zA-Z0-9]+)": ToolIcon\(/', $swift, $ios);
        preg_match_all('/"([a-zA-Z0-9]+)" to ToolIcon\(/', $kotlin, $android);

        sort($ios[1]);
        sort($android[1]);

        expect($ios[1])->not->toBeEmpty()
            ->and($android[1])->toBe($ios[1]);
    });

    /**
     * Both path parsers understand M, L, C and Z and nothing else. An SVG arc
     * pasted in from a design tool parses to a stray stroke — which is exactly
     * what a clock face did, and it looked like a rendering glitch rather than
     * a bad path.
     */
    it('draws every glyph with commands the parsers actually implement', function (string $file, string $pattern) {
        preg_match_all($pattern, file_get_contents(__DIR__.'/../resources/'.$file), $found);

        foreach ($found[1] as $path) {
            expect(preg_replace('/[^A-Za-z]/', '', $path))
                ->toMatch('/^[MLCZ]*$/');
        }
    })->with([
        ['ios/WysiwygEditorFunctions.swift', '/ToolIcon\(path: "([^"]+)"/'],
        ['android/WysiwygEditorFunctions.kt', '/ToolIcon\("([^"]+)"/'],
    ]);

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

        // EVERY dispatcher, not any one of them. iOS has two — the toolbar
        // calls one and delegates document-wide tools to the other — and a
        // tool named in only the second is a button that does nothing.
        // `checklist` was exactly that, and this test passed anyway.
        foreach ($functions as $pattern) {
            expect(preg_match($pattern, $source, $m))->toBe(1, "no dispatcher matched {$pattern}");

            preg_match_all('/"([a-zA-Z0-9]+)"/', $m[1], $named);

            $covered = $named[1];

            if (str_contains($m[1], 'INSERT_TOOLS') || str_contains($m[1], 'insertTools')) {
                $covered = array_merge($covered, WysiwygEditor::INSERT_TOOLS);
            }

            $absent = array_values(array_diff(WysiwygEditor::AVAILABLE_TOOLS, $covered));

            expect($absent)->toBe([], 'tools missing from a dispatcher: '.implode(', ', $absent));
        }

        $handled = '';

        foreach ($functions as $pattern) {
            preg_match($pattern, $source, $m);
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

describe('Host sheets', function () {
    it('has none unless the host declares them', function () {
        expect(editor()->config('')['sheets'])->toBe([]);
    });

    /**
     * The editor owns its own window, so a sheet the host drew would open
     * BEHIND it. Declaring it here is not ceremony — it is the only way the
     * app's own choices can appear over the editor at all.
     */
    it('carries a declared sheet through, keyed or listed', function (array $sheets) {
        $config = editor()->config('', ['sheets' => $sheets]);

        expect($config['sheets'])->toBe([[
            'id' => 'audience',
            'title' => 'Who can see your post?',
            'style' => 'list',
            'options' => [
                ['id' => 'anyone', 'label' => 'Anyone', 'detail' => 'On or off the network', 'selected' => true],
                ['id' => 'connections', 'label' => 'Connections only'],
            ],
        ]]);
    })->with([
        'keyed by id' => [['audience' => [
            'title' => 'Who can see your post?',
            'options' => [
                ['id' => 'anyone', 'label' => 'Anyone', 'detail' => 'On or off the network', 'selected' => true],
                ['id' => 'connections', 'label' => 'Connections only'],
            ],
        ]]],
        'listed with an id' => [[[
            'id' => 'audience',
            'title' => 'Who can see your post?',
            'options' => [
                ['id' => 'anyone', 'label' => 'Anyone', 'detail' => 'On or off the network', 'selected' => true],
                ['id' => 'connections', 'label' => 'Connections only'],
            ],
        ]]],
    ]);

    it('offers a grid, for the tiles a composer opens onto', function () {
        $config = editor()->config('', ['sheets' => ['compose' => [
            'style' => 'grid',
            'options' => [['id' => 'media', 'label' => 'Media', 'icon' => 'image']],
        ]]]);

        expect($config['sheets'][0]['style'])->toBe('grid');
    });

    it('falls back to a list for a style it does not know', function () {
        $config = editor()->config('', ['sheets' => ['a' => [
            'style' => 'carousel',
            'options' => [['id' => 'x', 'label' => 'X']],
        ]]]);

        expect($config['sheets'][0]['style'])->toBe('list');
    });

    /** A sheet with nothing in it would open onto a blank panel. */
    it('drops a sheet that could not work', function (array $sheets) {
        expect(editor()->config('', ['sheets' => $sheets])['sheets'])->toBe([]);
    })->with([
        'no options' => [['a' => ['title' => 'Empty']]],
        'no id' => [[['options' => [['id' => 'x', 'label' => 'X']]]]],
        'options that could not work' => [['a' => ['options' => [['label' => 'No id'], ['id' => 'no-label']]]]],
    ]);

    it('ignores keys an option does not have', function () {
        $config = editor()->config('', ['sheets' => ['a' => [
            'options' => [['id' => 'x', 'label' => 'X', 'onTap' => 'doSomething()']],
        ]]]);

        expect($config['sheets'][0]['options'][0])->toBe(['id' => 'x', 'label' => 'X']);
    });
});

describe('Composer layout', function () {
    it('puts the tools at the leading edge by default', function () {
        expect(editor()->config('')['toolbarAlign'])->toBe('leading');
    });

    /**
     * A bar of two buttons reads as an oversight at the left edge; LinkedIn
     * parks its photo and "+" in the corner.
     */
    it('can park a short bar in the corner', function () {
        expect(editor()->config('', ['toolbarAlign' => 'trailing'])['toolbarAlign'])->toBe('trailing');
    });

    it('falls back for an alignment it does not know', function () {
        expect(editor()->config('', ['toolbarAlign' => 'middle'])['toolbarAlign'])->toBe('leading');
    });

    it('puts the author picture beside the writing by default', function () {
        expect(editor()->config('')['avatarPlacement'])->toBe('text');
    });

    it('can move the picture into the header, leaving the writing full width', function (string $where) {
        expect(editor()->config('', ['avatarPlacement' => $where])['avatarPlacement'])->toBe($where);
    })->with(['header', 'none']);
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
            ['id' => 'tag', 'label' => 'Tag people', 'icon' => 'image', 'placement' => 'row', 'style' => 'row'],
            ['id' => 'audience', 'label' => 'Everyone can reply', 'value' => 'Everyone', 'placement' => 'row', 'style' => 'row'],
        ]);
    });

    /**
     * LinkedIn's audience picker lives beside Post, not below the fold — a
     * control that decides who sees the post belongs next to the button that
     * sends it.
     */
    it('can put a control in the header, where a chip is the only thing that fits', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'audience', 'label' => 'Anyone', 'placement' => 'header'],
        ]]);

        expect($config['accessories'][0]['placement'])->toBe('header')
            ->and($config['accessories'][0]['style'])->toBe('chip');
    });

    it('lets a header control ask for a bare icon instead', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'schedule', 'label' => 'Schedule', 'icon' => 'clock',
                'placement' => 'header', 'style' => 'icon'],
        ]]);

        expect($config['accessories'][0]['style'])->toBe('icon');
    });

    it('falls back for a placement or style it does not know', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'a', 'label' => 'A', 'placement' => 'floating', 'style' => 'neon'],
        ]]);

        expect($config['accessories'][0]['placement'])->toBe('row')
            ->and($config['accessories'][0]['style'])->toBe('row');
    });

    it('carries the sheet a control opens', function () {
        $config = editor()->config('', ['accessories' => [
            ['id' => 'audience', 'label' => 'Anyone', 'sheet' => 'who-can-see'],
        ]]);

        expect($config['accessories'][0]['sheet'])->toBe('who-can-see');
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

        expect($config['accessories'][0])
            ->toBe(['id' => 'a', 'label' => 'A', 'placement' => 'row', 'style' => 'row']);
    });
});

describe('Backing out', function () {
    it('offers to discard by default', function () {
        $config = editor()->config('');

        expect($config['cancelMode'])->toBe('discard')
            ->and($config['cancelStyle'])->toBe('text');
    });

    it('can offer a draft instead, and a close icon', function () {
        $config = editor()->config('', ['cancelMode' => 'draft', 'cancelStyle' => 'icon']);

        expect($config['cancelMode'])->toBe('draft')
            ->and($config['cancelStyle'])->toBe('icon');
    });

    it('falls back for anything unrecognised', function () {
        $config = editor()->config('', ['cancelMode' => 'nope', 'cancelStyle' => 'nope']);

        expect($config['cancelMode'])->toBe('discard')
            ->and($config['cancelStyle'])->toBe('text');
    });

    it('labels every button the draft prompt shows', function () {
        foreach (['draftTitle', 'draftMessage', 'draftSave', 'draftDelete'] as $key) {
            expect(WysiwygEditor::STRINGS)->toHaveKey($key);
        }
    });
});

describe('Host toolbar buttons and avatar', function () {
    it('has no extra buttons unless the host adds them', function () {
        expect(editor()->config('')['customTools'])->toBe([])
            ->and(editor()->config('')['avatar'])->toBe('');
    });

    it('carries id, icon and label through in order', function () {
        $config = editor()->config('', ['customTools' => [
            ['id' => 'gif', 'icon' => 'image', 'label' => 'GIF'],
            ['id' => 'schedule', 'icon' => 'link'],
        ]]);

        expect($config['customTools'])->toBe([
            ['id' => 'gif', 'icon' => 'image', 'label' => 'GIF'],
            ['id' => 'schedule', 'icon' => 'link'],
        ]);
    });

    /**
     * A button with no id could never report a tap; one with no icon would
     * draw as a blank gap in the bar.
     */
    it('drops buttons that could not work', function (array $tool) {
        expect(editor()->config('', ['customTools' => [$tool]])['customTools'])->toBe([]);
    })->with([
        [['icon' => 'image']],
        [['id' => 'no-icon']],
        [['id' => '  ', 'icon' => 'image']],
    ]);

    it('carries the author picture', function () {
        expect(editor()->config('', ['avatar' => '/tmp/me.jpg'])['avatar'])->toBe('/tmp/me.jpg');
    });

    it('offers camera as a distinct insert tool', function () {
        // A photo you TAKE is not a photo you pick — the host opens a
        // different screen for each.
        expect(WysiwygEditor::INSERT_TOOLS)->toContain('camera')
            ->and(WysiwygEditor::AVAILABLE_TOOLS)->toContain('camera')
            ->and(WysiwygEditor::TOOL_LABEL_KEYS)->toHaveKey('camera');
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
        loadHostTheme(['fonts' => ['default' => 'Sora']]);

        expect(editor()->config('')['typography']['fontFamily'])->toBe('Sora');

        resetHostTheme();
    });

    it('lets an explicit family win over the host font', function () {
        loadHostTheme(['fonts' => ['default' => 'Sora']]);

        expect(editor()->config('', ['typography' => ['fontFamily' => 'Inter']])['typography']['fontFamily'])
            ->toBe('Inter');

        resetHostTheme();
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
        loadHostTheme([
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

        resetHostTheme();
    });

    it('stays empty when the host has no tokens, so native defaults apply', function () {
        resetHostTheme();

        $config = editor()->config('');

        expect($config['themeLight'])->toBe([])
            ->and($config['themeDark'])->toBe([]);
    });

    it('ignores malformed host colours rather than passing them through', function () {
        loadHostTheme(['light' => ['background' => 'rebeccapurple']]);

        expect(editor()->config('')['themeLight'])->toBe([]);

        resetHostTheme();
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

describe('Counts readout', function () {
    /**
     * A cap is not a request for a readout. LinkedIn's composer has a
     * 3000-character allowance and shows no counter at all — the cap decides
     * when SAVE refuses, `counts` decides what the writer is told.
     */
    it('shows nothing for a cap alone, because counts is what asks', function () {
        expect(editor()->config('', ['maxLength' => 3000])['counts'])->toBe([]);
    });

    it('turns the character count into n/limit when there is a cap', function () {
        $config = editor()->config('', ['maxLength' => 500, 'counts' => ['characters']]);

        expect($config['counts'])->toBe(['characters'])
            ->and($config['maxLength'])->toBe(500);
    });
});

describe('Post backgrounds', function () {
    it('offers none unless the host supplies them', function () {
        expect(editor()->config('')['backgrounds'])->toBe([]);
    });

    it('carries a flat colour and a gradient through, keyed or listed', function (array $backgrounds) {
        expect(editor()->config('', ['backgrounds' => $backgrounds])['backgrounds'])->toBe([
            ['id' => 'plain', 'from' => '#1877F2', 'textColor' => '#FFFFFF'],
            ['id' => 'sunset', 'from' => '#FF6B6B', 'to' => '#FFD93D', 'textColor' => '#1C1E21'],
        ]);
    })->with([
        'keyed by id' => [[
            'plain' => ['from' => '1877F2'],
            'sunset' => ['from' => '#ff6b6b', 'to' => '#FFD93D', 'textColor' => '#1c1e21'],
        ]],
        'listed with an id' => [[
            ['id' => 'plain', 'from' => '#1877F2'],
            ['id' => 'sunset', 'from' => '#FF6B6B', 'to' => '#FFD93D', 'textColor' => '#1C1E21'],
        ]],
    ]);

    /** White on anything dark is the usual answer, so it is the default. */
    it('defaults the text to white', function () {
        $backgrounds = editor()->config('', ['backgrounds' => ['a' => ['from' => '#000000']]])['backgrounds'];

        expect($backgrounds[0]['textColor'])->toBe('#FFFFFF');
    });

    it('drops a background it could not draw', function (array $background) {
        expect(editor()->config('', ['backgrounds' => [$background]])['backgrounds'])->toBe([]);
    })->with([
        'no id' => [['from' => '#FFFFFF']],
        'no colour' => [['id' => 'a']],
        'not a colour' => [['id' => 'a', 'from' => 'cornflower']],
    ]);

    /**
     * A paragraph set in 28pt white on orange is unreadable, which is why
     * Facebook drops the background once the post stops being a few words.
     */
    it('stops holding a post large past a length the host can set', function () {
        expect(editor()->config('')['backgroundMaxLength'])
            ->toBe(WysiwygEditor::BACKGROUND_MAX_LENGTH)
            ->and(editor()->config('', ['backgroundMaxLength' => 80])['backgroundMaxLength'])->toBe(80);
    });
});

describe('Attachments', function () {
    /**
     * Most servers want the prose in one table and the files in another. The
     * editor uploads nothing — the endpoint belongs to the app — so this is
     * the split, and an app should not have to learn the document format to
     * do it itself.
     */
    it('separates the files from the prose', function () {
        $json = json_encode(['blocks' => [
            ['type' => 'p', 'runs' => [['text' => 'Shipping today']]],
            ['type' => 'image', 'localPath' => '/var/mobile/IMG_1.HEIC', 'alt' => 'Harbour', 'uploadId' => 'u-1'],
            ['type' => 'video', 'src' => 'https://cdn.example.com/a.mp4', 'caption' => 'Dawn'],
        ]]);

        expect(editor()->attachments($json))->toBe([
            ['kind' => 'image', 'path' => '/var/mobile/IMG_1.HEIC', 'url' => '',
                'alt' => 'Harbour', 'caption' => '', 'uploadId' => 'u-1'],
            ['kind' => 'video', 'path' => '', 'url' => 'https://cdn.example.com/a.mp4',
                'alt' => '', 'caption' => 'Dawn', 'uploadId' => ''],
        ]);
    });

    /**
     * Which to do next must never be ambiguous: a device path means it still
     * needs uploading, a url means it is already yours.
     */
    it('fills exactly one of path and url', function () {
        $json = json_encode(['blocks' => [
            ['type' => 'image', 'localPath' => '/tmp/a.jpg'],
            ['type' => 'image', 'src' => 'https://cdn.example.com/b.jpg'],
        ]]);

        foreach (editor()->attachments($json) as $file) {
            expect($file['path'] === '')->not->toBe($file['url'] === '');
        }
    });

    /** They travel in the document; they are not files. */
    it('leaves polls, dividers and embeds out of it', function () {
        $json = json_encode(['blocks' => [
            ['type' => 'poll', 'question' => 'Ship it?'],
            ['type' => 'divider'],
            ['type' => 'embed', 'url' => 'https://youtu.be/x'],
        ]]);

        expect(editor()->attachments($json))->toBe([]);
    });

    it('skips a block the user took the file back out of', function () {
        $json = json_encode(['blocks' => [['type' => 'image', 'alt' => 'nothing here']]]);

        expect(editor()->attachments($json))->toBe([]);
    });

    it('returns nothing for a document it cannot read', function (string $json) {
        expect(editor()->attachments($json))->toBe([]);
    })->with(['not json', '', '{}', '{"blocks":"nope"}']);
});

describe('Taking only what you need', function () {
    /**
     * The whole premise: an app picks the tools it wants and pays for nothing
     * else. A composer that only needs bold should not end up with a poll
     * composer, a media strip and a colour picker it never asked for.
     */
    it('gives an app exactly the tools it asked for', function (array $toolbar) {
        expect(editor()->config('', ['toolbar' => $toolbar])['toolbar'])->toBe($toolbar);
    })->with([
        'one tool' => [['bold']],
        'writing, no media' => [['bold', 'italic', 'link']],
        'media, no writing' => [['image', 'video']],
    ]);

    /** An explicit empty list means no bar, not a fallback to everything. */
    it('draws no toolbar at all when asked for none', function () {
        expect(editor()->config('', ['toolbar' => []])['toolbar'])->toBe([]);
    });

    /**
     * Everything that costs something is opt-in. An editor configured with
     * nothing carries no media, no polls, no colours, no host controls and no
     * lookups — which is what makes it usable as a plain text field.
     */
    it('carries nothing an app did not ask for', function () {
        $config = editor()->config('');

        expect($config['backgrounds'])->toBe([])
            ->and($config['accessories'])->toBe([])
            ->and($config['customTools'])->toBe([])
            ->and($config['sheets'])->toBe([])
            ->and($config['counts'])->toBe([])
            ->and($config['avatar'])->toBe('')
            ->and($config['maxLength'])->toBe(0)
            ->and($config['validation'])->toBe([]);
    });

    /**
     * Media is the expensive one: it drags in a picker, an uploader and the
     * events that carry them. An app that never lists a media tool never has
     * to answer MediaRequested at all.
     */
    it('asks for no media unless a media tool was listed', function () {
        $config = editor()->config('', ['toolbar' => ['bold', 'italic', 'bulletList']]);

        expect(array_intersect($config['toolbar'], WysiwygEditor::INSERT_TOOLS))->toBe([]);
    });

    /** Mentions cost a round trip per keystroke, so they are opt-out too. */
    it('watches for no trigger characters when told not to', function () {
        expect(editor()->config('', ['triggers' => false])['triggers'])->toBe([]);
    });
});

describe('The README describes the plugin that exists', function () {
    /**
     * Documentation drifts silently and a developer only finds out when the
     * thing they copied does nothing. Seven options shipped undocumented
     * before this test existed.
     */
    it('documents every option the editor accepts', function () {
        $readme = file_get_contents(__DIR__.'/../README.md');
        $config = editor()->config('');

        // Internal plumbing the caller never passes.
        $internal = ['content', 'contentJson', 'themeLight', 'themeDark',
            'pollMinOptions', 'pollMaxOptions', 'pollDurations'];

        foreach (array_diff(array_keys($config), $internal) as $option) {
            expect($readme)->toContain("`{$option}`");
        }
    });

    it('lists every tool a caller can put on the toolbar', function () {
        $readme = file_get_contents(__DIR__.'/../README.md');

        foreach (WysiwygEditor::AVAILABLE_TOOLS as $tool) {
            expect($readme)->toContain("`{$tool}`");
        }
    });

    it('names every event the editor can dispatch', function () {
        $readme = file_get_contents(__DIR__.'/../README.md');

        foreach (glob(__DIR__.'/../src/Events/*.php') as $file) {
            expect($readme)->toContain(basename($file, '.php'));
        }
    });

    it('names every method the facade offers', function () {
        $readme = file_get_contents(__DIR__.'/../README.md');
        $facade = file_get_contents(__DIR__.'/../src/Facades/WysiwygEditor.php');

        preg_match_all('/@method static \S+ (\w+)\(/', $facade, $methods);

        foreach ($methods[1] as $method) {
            expect($readme)->toContain($method);
        }
    });
});

describe('Release metadata', function () {
    /**
     * The manifest still said 0.1.0 at the point v0.4.0 was tagged — three
     * releases of drift, in the one file a NativePHP build reads.
     */
    it('carries the version the changelog most recently released', function () {
        $manifest = json_decode(file_get_contents(__DIR__.'/../nativephp.json'), true);

        preg_match('/^## \[(\d+\.\d+\.\d+)\]/m', file_get_contents(__DIR__.'/../CHANGELOG.md'), $latest);

        expect($manifest['version'])->toBe($latest[1]);
    });
});

describe('Nothing declared without somewhere to land', function () {
    /**
     * The bug this plugin keeps producing: a key is added to PHP and to ONE
     * platform, and the feature silently does nothing on the other. It happened
     * to `avatarPlacement`, and the only symptom was an avatar drawn twice.
     *
     * The config is untrusted JSON, so each platform reads the keys it knows by
     * name — which means there are three copies of every key and no compiler to
     * keep them in step.
     */
    it('reads every option on both platforms', function () {
        $missing = [];

        foreach (nativeSources() as $platform => $source) {
            foreach (array_keys(editor()->config('')) as $key) {
                if (! str_contains($source, "\"{$key}\"")) {
                    $missing[] = "{$platform} never reads the {$key} option";
                }
            }
        }

        expect($missing)->toBe([]);
    });

    /**
     * The nested keys are the easier ones to forget: nothing references them
     * from PHP except the resolver, and a missing one degrades quietly — a
     * sheet option with no `detail`, a background with no `to`.
     */
    it('reads every nested key on both platforms', function (array $keys, string $what) {
        $missing = [];

        foreach (nativeSources() as $platform => $source) {
            foreach ($keys as $key) {
                // A bracket READ, not merely the name somewhere in the file:
                // several of these double as tool names, so `textColor` appears
                // eleven times in the Kotlin and presence alone proves nothing.
                if (! preg_match('/\w\["'.preg_quote($key, '/').'"\]/', $source)) {
                    $missing[] = "{$platform} never reads {$what}.{$key}";
                }
            }
        }

        expect($missing)->toBe([]);
    })->with([
        [WysiwygEditor::ACCESSORY_KEYS, 'accessory'],
        [WysiwygEditor::CUSTOM_TOOL_KEYS, 'customTool'],
        [WysiwygEditor::SHEET_KEYS, 'sheet'],
        [WysiwygEditor::SHEET_OPTION_KEYS, 'sheetOption'],
        [WysiwygEditor::BACKGROUND_KEYS, 'background'],
    ]);

    /**
     * A control naming a sheet that was never declared must still report its
     * tap. Doing nothing at all is the worst outcome: the app looks broken and
     * there is no event left to debug from.
     */
    it('looks the sheet up before presenting one, so an unknown name still reports', function (string $platform) {
        $source = nativeSources()[$platform];

        // Guarding on FINDING the sheet rather than merely on one having been
        // named is what makes the tap fall through to the event.
        expect($source)->toMatch('/sheets\.first(OrNull)?\s*[({]/')
            ->and($source)->toContain('accessoryTapped');
    })->with(['iOS', 'Android']);
});

describe('Slash commands', function () {
    /**
     * One pipeline spots a trigger, asks the host what matches and shows the
     * answer. Whether the pick writes a NAME or changes the BLOCK is a
     * property of the row — which is why `/h1` needs no machinery of its own.
     */
    it('carries a tool through, so a row can be a command', function () {
        $sent = captureCall(fn () => editor()->suggestions('h', [
            ['id' => 'h1', 'label' => 'Heading 1', 'icon' => 'h1', 'tool' => 'h1'],
        ]));

        expect($sent['suggestions'][0])
            ->toBe(['id' => 'h1', 'label' => 'Heading 1', 'icon' => 'h1', 'tool' => 'h1']);
    });

    it('leaves a mention row exactly as it was', function () {
        $sent = captureCall(fn () => editor()->suggestions('gr', [
            ['id' => 'u2', 'label' => 'Grace Hopper', 'detail' => 'Compiler pioneer'],
        ]));

        expect($sent['suggestions'][0])
            ->toBe(['id' => 'u2', 'label' => 'Grace Hopper', 'detail' => 'Compiler pioneer']);
    });

    /** A slash is a trigger like any other; nothing about it is special. */
    it('takes a slash as a trigger like any other character', function () {
        $config = editor()->config('', ['triggers' => ['/' => 'command']]);

        expect($config['triggers'])->toBe(['/' => 'command']);
    });

    it('still drops a row that could not be shown', function (array $row) {
        $sent = captureCall(fn () => editor()->suggestions('x', [$row]));

        expect($sent['suggestions'])->toBe([]);
    })->with([
        'no id' => [['label' => 'Heading 1', 'tool' => 'h1']],
        'no label' => [['id' => 'h1', 'tool' => 'h1']],
    ]);
});

describe('Inserting text', function () {
    /**
     * The seam a HOST command needs. `/date` comes back as ToolTapped with the
     * trigger already deleted — without this the app could offer the command
     * and never complete it.
     */
    it('sends the text a host wants written at the caret', function () {
        $sent = captureCall(fn () => editor()->insertText('30 July 2026'));

        expect($sent)->toBe(['text' => '30 July 2026']);
    });

    it('sends nothing for an empty string', function () {
        $GLOBALS['nativephp_calls'] = [];

        editor()->insertText('');

        expect($GLOBALS['nativephp_calls'])->toBe([]);
    });
});

describe('An editor that saves as you type', function () {
    /**
     * Apple Notes has no Save button because there is nothing to save — the
     * note is already written. A second button that also saves is a lie about
     * what the first one did.
     */
    it('offers a style with no save button at all', function () {
        expect(editor()->config('', ['saveStyle' => 'none'])['saveStyle'])->toBe('none');
    });

    it('still falls back for a style it does not know', function () {
        expect(editor()->config('', ['saveStyle' => 'sparkle'])['saveStyle'])->toBe('text');
    });

    /**
     * With `none`, the close control commits — so both platforms have to know
     * about it, or one of them silently throws the last edits away.
     */
    it('is understood by both platforms', function () {
        foreach (nativeSources() as $platform => $source) {
            expect($source)->toContain('"none"');
        }
    });

    /** The autosave seam it pairs with. */
    it('pairs with a debounced change event', function () {
        expect(editor()->config('', ['changeDebounce' => 800])['changeDebounce'])->toBe(800);
    });
});

describe('Packaging', function () {
    /**
     * What `php artisan native:plugin:validate` checks, run here so a broken
     * package fails in THIS suite rather than in somebody's build. The
     * official command needs a host app; these do not.
     */
    it('declares itself as a NativePHP plugin', function () {
        $composer = json_decode(file_get_contents(__DIR__.'/../composer.json'), true);

        expect($composer['type'])->toBe('nativephp-plugin')
            ->and($composer['extra']['nativephp']['manifest'])->toBe('nativephp.json');
    });

    it('points at a service provider that exists', function () {
        $composer = json_decode(file_get_contents(__DIR__.'/../composer.json'), true);

        foreach ($composer['extra']['laravel']['providers'] as $provider) {
            expect(class_exists($provider))->toBeTrue();
        }
    });

    /**
     * A hook naming a command nobody registered fails at build time, in
     * somebody else's project, with no clue where it came from.
     */
    it('registers every hook command it declares', function () {
        $manifest = json_decode(file_get_contents(__DIR__.'/../nativephp.json'), true);
        $provider = file_get_contents(__DIR__.'/../src/WysiwygEditorServiceProvider.php');

        foreach ($manifest['hooks'] ?? [] as $signature) {
            $classes = glob(__DIR__.'/../src/Commands/*.php');
            $found = false;

            foreach ($classes as $file) {
                if (str_contains(file_get_contents($file), $signature)) {
                    $found = true;
                    expect($provider)->toContain(basename($file, '.php'));
                }
            }

            expect($found)->toBeTrue("no command declares the signature {$signature}");
        }
    });

    /** Every asset the manifest promises has to be in the package. */
    it('ships every asset it declares', function () {
        $manifest = json_decode(file_get_contents(__DIR__.'/../nativephp.json'), true);

        // Declared per platform: {"android": [...], "ios": [...]}.
        $declared = array_merge(...array_values($manifest['assets'] ?? ['none' => []]));

        foreach ($declared as $asset) {
            $path = is_array($asset) ? ($asset['source'] ?? $asset['path'] ?? '') : $asset;

            expect($path)->not->toBe('')
                ->and(file_exists(__DIR__.'/../'.ltrim($path, '/')))->toBeTrue();
        }

        // An empty list is legitimate — this plugin ships no bundled files —
        // so the assertion that matters is that the KEYS are there to read.
        expect($manifest['assets'])->toHaveKeys(['android', 'ios']);
    });

    /**
     * The native sources are found by convention rather than listed, so the
     * manifest cannot catch them going missing. Nothing else would either:
     * the build would simply compile a plugin with no implementation.
     */
    it('ships the native sources both platforms compile', function (string $path) {
        $file = __DIR__.'/../'.$path;

        expect(file_exists($file))->toBeTrue()
            ->and(filesize($file))->toBeGreaterThan(1000);
    })->with([
        'resources/ios/WysiwygEditorFunctions.swift',
        'resources/android/WysiwygEditorFunctions.kt',
    ]);
});

describe('Reachable from outside the toolbar', function () {
    /**
     * A slash command has no selection to act on, so it can only INSERT. The
     * runner must therefore reach every block tool — `table` reached both
     * toolbar dispatchers and still did nothing when typed as `/table`,
     * because this third way in did not name it.
     *
     * Marks are deliberately absent: `/bold` would have nothing to embolden.
     */
    it('runs every block tool from a slash command', function (string $file, string $pattern) {
        $source = file_get_contents($this->pluginPath.$file);

        expect(preg_match($pattern, $source, $m))->toBe(1, "no slash runner matched {$pattern}");

        preg_match_all('/"([a-zA-Z0-9]+)"/', $m[1], $found);

        $covered = $found[1];

        if (str_contains($m[1], 'INSERT_TOOLS') || str_contains($m[1], 'insertTools')) {
            $covered = array_merge($covered, WysiwygEditor::INSERT_TOOLS);
        }

        $reachable = array_merge(WysiwygEditor::BLOCK_TOOLS, WysiwygEditor::INSERT_TOOLS);
        $missing = array_values(array_diff($reachable, $covered));

        expect($missing)->toBe([], 'not reachable from a slash command: '.implode(', ', $missing));
    })->with([
        [
            '/resources/ios/WysiwygEditorFunctions.swift',
            '/private func runSuggestedTool\(_ tool: String, on model: WysiwygEditorModel\) \{(.*?)\n    \}/s',
        ],
        [
            '/resources/android/WysiwygEditorFunctions.kt',
            '/fun runSuggestedTool\(tool: String, controller: EditorController\) \{(.*?)\n        \}/s',
        ],
    ]);
});

describe('Adopting the host application palette', function () {
    /**
     * NativeUI renamed its namespace when it caught up with NativePHP 4.0 —
     * `Nativephp\NativeUi` became `Native\Mobile\UI` — and both are in the
     * wild. Every lookup of it here is guarded by `class_exists`, so knowing
     * only one name does not crash: a host on the other version simply reads
     * as "no theme installed" and the editor falls back to its own colours.
     *
     * This suite exists because that happened. The stub carried the OLD name,
     * these tests passed against it, and the editor was meanwhile drawing its
     * fallback orange over a blue application on a real device.
     */
    it('knows both names NativeUI has published its Theme under', function () {
        $names = (new ReflectionClass(WysiwygEditor::class))->getConstant('NATIVE_UI_THEMES');

        $missing = array_values(array_diff(
            ['Native\Mobile\UI\Theme', 'Nativephp\NativeUi\Theme'],
            $names,
        ));

        expect($missing)->toBe([], 'namespaces NativeUI has used that we would miss: '.implode(', ', $missing));
    });

    /**
     * Which one wins cannot be observed by installing them one at a time —
     * the suite stubs both, and a real app has exactly one. So this pins the
     * preference order instead, and the test below proves the palette is
     * actually read through whichever the resolver returned.
     */
    it('prefers the name NativeUI uses now', function () {
        $editor = new WysiwygEditor;

        $resolve = (new ReflectionClass($editor))->getMethod('hostThemeClass');
        $resolve->setAccessible(true);

        expect($resolve->invoke($editor))->toBe('Native\Mobile\UI\Theme');
    });

    it('reads the palette out of it', function () {
        loadHostTheme(['light' => ['primary' => '#2563EB', 'on-surface' => '#27272A']]);

        $editor = new WysiwygEditor;
        $host = (new ReflectionClass($editor))->getMethod('hostTheme');
        $host->setAccessible(true);

        expect($host->invoke($editor, 'light'))->toMatchArray(['accent' => '#2563EB']);

        resetHostTheme();
    });
});
