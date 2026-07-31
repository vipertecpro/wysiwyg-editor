<?php

namespace Native\Mobile\UI;

/**
 * The same stand-in as tests/Stubs/NativeUiTheme.php, under the name NativeUI
 * moved to for NativePHP 4.0.
 *
 * Both exist because both are in the wild, and the plugin has to find either.
 * Keeping only the older one is what let a namespace rename read as "no theme
 * installed" while every test still passed.
 */
class Theme
{
    /** @var array<string, array<string, string>> */
    private static array $tokens = [];

    /**
     * @param  array<string, array<string, string>>  $tokens
     */
    public static function load(array $tokens): void
    {
        self::$tokens = $tokens;
    }

    /**
     * @return array<string, array<string, string>>
     */
    public static function all(): array
    {
        return self::$tokens;
    }

    public static function reset(): void
    {
        self::$tokens = [];
    }
}
