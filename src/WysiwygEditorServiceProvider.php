<?php

namespace Vipertecpro\WysiwygEditor;

use Illuminate\Support\ServiceProvider;
use Vipertecpro\WysiwygEditor\Commands\CopyAssetsCommand;

class WysiwygEditorServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->app->singleton(WysiwygEditor::class, function () {
            return new WysiwygEditor;
        });
    }

    public function boot(): void
    {
        // Register plugin hook commands
        if ($this->app->runningInConsole()) {
            $this->commands([
                CopyAssetsCommand::class,
            ]);
        }
    }
}
