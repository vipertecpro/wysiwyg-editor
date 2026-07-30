<?php

namespace Vipertecpro\WysiwygEditor\Testing;

use Native\Mobile\Testing\FakeBridge;

/**
 * Test vocabulary for apps that use this editor.
 *
 * NativePHP 4.0 lets a plugin teach its own assertions to the FakeBridge, so
 * an app testing its integration reads in terms of the editor rather than of
 * bridge method strings:
 *
 *     Native::test(LinkedInFeed::class)
 *         ->call('compose')
 *         ->assertEditorOpened();
 *
 *     Native::test(NotionPages::class)
 *         ->call('onSuggestionRequested', 'command', 'todo')
 *         ->assertSuggestionsOffered(['To-do list']);
 *
 * Without this, the same test has to know that opening an editor means a
 * `WysiwygEditor.Open` call carrying JSON — which is this plugin's business,
 * not the app's.
 */
class BridgeMacros
{
    /**
     * Every bridge method the editor can call, in the order a reader meets
     * them. Kept beside the macros so a new one cannot be added without
     * somebody noticing there is no assertion for it.
     */
    public const METHODS = [
        'open' => 'WysiwygEditor.Open',
        'insertMedia' => 'WysiwygEditor.InsertMedia',
        'updateUpload' => 'WysiwygEditor.UpdateUpload',
        'preview' => 'WysiwygEditor.Preview',
        'setAccessory' => 'WysiwygEditor.SetAccessory',
        'suggestions' => 'WysiwygEditor.Suggestions',
        'runTool' => 'WysiwygEditor.RunTool',
        'insertText' => 'WysiwygEditor.InsertText',
    ];

    /**
     * Teach the FakeBridge this plugin's assertions.
     *
     * Idempotent, and silent when the testing suite is not installed — a
     * production app should not pay for test helpers it never calls.
     */
    public static function register(): void
    {
        // `macro` itself is the thing older versions lack, so it has to be
        // tested for BEFORE `hasMacro` — asking a non-macroable class whether
        // it has a macro is the same fatal error, one call earlier.
        if (! class_exists(FakeBridge::class) || ! method_exists(FakeBridge::class, 'macro')) {
            return;
        }

        if (FakeBridge::hasMacro('assertEditorOpened')) {
            return;
        }

        /** The editor was opened, optionally with a particular option set. */
        FakeBridge::macro('assertEditorOpened', function (?string $option = null, mixed $value = null) {
            return $this->assertCalled(
                BridgeMacros::METHODS['open'],
                fn (array $parameters) => $option === null
                    || (json_decode($parameters['config'] ?? '[]', true)[$option] ?? null) === $value,
            );
        });

        FakeBridge::macro('assertEditorNotOpened', function () {
            return $this->assertNotCalled(BridgeMacros::METHODS['open']);
        });

        /**
         * The host answered a lookup. Pass labels to say WHICH rows — the
         * usual reason a suggestion test fails is the filtering, not the
         * plumbing.
         */
        FakeBridge::macro('assertSuggestionsOffered', function (?array $labels = null) {
            return $this->assertCalled(
                BridgeMacros::METHODS['suggestions'],
                function (array $parameters) use ($labels) {
                    if ($labels === null) {
                        return true;
                    }

                    $offered = array_column($parameters['suggestions'] ?? [], 'label');

                    return $offered === $labels;
                },
            );
        });

        FakeBridge::macro('assertNoSuggestionsOffered', function () {
            return $this->assertNotCalled(BridgeMacros::METHODS['suggestions']);
        });

        /** A picked file was handed back to the editor. */
        FakeBridge::macro('assertMediaInserted', function (?string $kind = null) {
            return $this->assertCalled(
                BridgeMacros::METHODS['insertMedia'],
                fn (array $parameters) => $kind === null || ($parameters['kind'] ?? null) === $kind,
            );
        });

        /** One of the editor's own tools was asked for from outside the bar. */
        FakeBridge::macro('assertToolRun', function (string $tool) {
            return $this->assertCalled(
                BridgeMacros::METHODS['runTool'],
                fn (array $parameters) => ($parameters['tool'] ?? null) === $tool,
            );
        });

        /** A host command wrote something at the caret. */
        FakeBridge::macro('assertTextInserted', function (?string $text = null) {
            return $this->assertCalled(
                BridgeMacros::METHODS['insertText'],
                fn (array $parameters) => $text === null || ($parameters['text'] ?? null) === $text,
            );
        });

        /** A host control was updated to show the choice that was made. */
        FakeBridge::macro('assertAccessorySet', function (string $accessory, ?string $value = null) {
            return $this->assertCalled(
                BridgeMacros::METHODS['setAccessory'],
                fn (array $parameters) => ($parameters['accessory'] ?? null) === $accessory
                    && ($value === null || ($parameters['value'] ?? null) === $value),
            );
        });
    }
}
