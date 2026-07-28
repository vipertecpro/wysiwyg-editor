<?php

namespace Nativephp\NativeUi;

/**
 * Stand-in for NativeUI's theme registry.
 *
 * `nativephp/native-ui` is an OPTIONAL peer: a host app that uses it gets
 * automatic theme adoption, and one that doesn't falls back to the editor's
 * system-adaptive defaults. The plugin therefore cannot depend on it, but the
 * token-mapping logic still needs covering — so the suite loads this stub only
 * when the real class is absent.
 *
 * Mirrors the subset the plugin touches: load / all / reset.
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
