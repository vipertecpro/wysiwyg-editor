<?php

namespace Vipertecpro\WysiwygEditor\Facades;

use Illuminate\Support\Facades\Facade;

/**
 * @method static void open(string $html = '', array $options = [])
 * @method static void insertMedia(string $kind, array $attributes = [])
 * @method static void uploadProgress(string $uploadId, float $fraction)
 * @method static void uploadCompleted(string $uploadId, string $url)
 * @method static void uploadFailed(string $uploadId, string $message = '')
 * @method static void setAccessory(string $accessory, string $label = '', string $value = '')
 * @method static void preview(string $kind, string $source, string $caption = '')
 * @method static string toMarkdown(string $json)
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
