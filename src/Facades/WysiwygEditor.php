<?php

namespace Vipertecpro\WysiwygEditor\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static void open(string $html = '', array $options = [])
 *
 * @see \Vipertecpro\WysiwygEditor\WysiwygEditor
 */
class WysiwygEditor extends Facade
{
    protected static function getFacadeAccessor(): string
    {
        return \Vipertecpro\WysiwygEditor\WysiwygEditor::class;
    }
}
