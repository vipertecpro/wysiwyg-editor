<?php

use Nativephp\NativeUi\Theme;

/*
|--------------------------------------------------------------------------
| Test Case
|--------------------------------------------------------------------------
*/

// nativephp/native-ui is an optional peer — see tests/Stubs/NativeUiTheme.php.
if (! class_exists(Theme::class)) {
    require __DIR__.'/Stubs/NativeUiTheme.php';
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
