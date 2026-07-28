<?php

/*
|--------------------------------------------------------------------------
| Test Case
|--------------------------------------------------------------------------
*/

// nativephp/native-ui is an optional peer — see tests/Stubs/NativeUiTheme.php.
if (! class_exists(\Nativephp\NativeUi\Theme::class)) {
    require __DIR__.'/Stubs/NativeUiTheme.php';
}

uses()->in('.');
