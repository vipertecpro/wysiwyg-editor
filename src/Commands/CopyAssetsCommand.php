<?php

namespace Vipertecpro\WysiwygEditor\Commands;

use Native\Mobile\Plugins\Commands\NativePluginHookCommand;

/**
 * Copy assets hook command for the WysiwygEditor plugin.
 *
 * This hook runs during the copy_assets phase of the build process. The
 * editor ships no binary assets today, so this is a no-op kept for the
 * plugin lifecycle contract.
 *
 * @see NativePluginHookCommand
 */
class CopyAssetsCommand extends NativePluginHookCommand
{
    protected $signature = 'nativephp:wysiwyg-editor:copy-assets';

    protected $description = 'Copy assets for the WysiwygEditor plugin';

    public function handle(): int
    {
        return self::SUCCESS;
    }
}
