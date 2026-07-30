<?php

namespace Vipertecpro\WysiwygEditor;

use Illuminate\Support\ServiceProvider;
use Vipertecpro\WysiwygEditor\Commands\CopyAssetsCommand;
use Vipertecpro\WysiwygEditor\Testing\BridgeMacros;

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

        // Teach the FakeBridge this plugin's assertions, so an app testing its
        // integration can say what it means rather than naming bridge methods.
        // Silent when the testing suite is absent.
        if ($this->app->runningUnitTests()) {
            BridgeMacros::register();
        }
    }
}
