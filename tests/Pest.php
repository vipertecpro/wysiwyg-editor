<?php

use Nativephp\NativeUi\Theme;

/*
|--------------------------------------------------------------------------
| Test Case
|--------------------------------------------------------------------------
*/

// nativephp/native-ui is an optional peer — see tests/Stubs/NativeUiTheme.php.
// BOTH namespaces it has published under are stubbed, because the plugin has
// to find either and covering only one is what let a rename go unnoticed.
if (! class_exists(Theme::class)) {
    require __DIR__.'/Stubs/NativeUiTheme.php';
}

if (! class_exists(\Native\Mobile\UI\Theme::class)) {
    require __DIR__.'/Stubs/NativeMobileUiTheme.php';
}

/**
 * Put a palette in front of the editor, whichever namespace it looks under.
 *
 * A real application has exactly one of these installed; the suite stubs both,
 * so a test that loaded only one would be asserting against a class the plugin
 * might not pick. Load both and the test says what it means: "the host has a
 * theme".
 *
 * @param  array<string, mixed>  $tokens
 */
function loadHostTheme(array $tokens): void
{
    Theme::load($tokens);
    \Native\Mobile\UI\Theme::load($tokens);
}

function resetHostTheme(): void
{
    Theme::reset();
    \Native\Mobile\UI\Theme::reset();
}

/**
 * Stand-in for the native bridge.
 *
 * Everything the editor SENDS goes through this one function, so recording it
 * is how a test sees what a host would actually receive. The real one is
 * injected by NativePHP at runtime and does not exist off-device.
 */
if (! function_exists('nativephp_call')) {
    function nativephp_call(string $name, string $payload = ''): void
    {
        $GLOBALS['nativephp_calls'][] = ['name' => $name, 'payload' => $payload];
    }
}

/**
 * Run `$action` and return the payload it sent over the bridge.
 *
 * @return array<string, mixed>
 */
function captureCall(callable $action): array
{
    $GLOBALS['nativephp_calls'] = [];

    $action();

    $last = end($GLOBALS['nativephp_calls']) ?: ['payload' => '[]'];

    return json_decode($last['payload'], true) ?? [];
}

uses()->in('.');
