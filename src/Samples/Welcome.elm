module Samples.Welcome exposing (source)


source : String
source =
    """# Welcome to Datadown

## what

Prototype interactive HTML & SVG using Markdown.

## colors
### blue
`#5bf`
### blue_darker
`#14f`
### pink
`#d6b`
### pink_darker
`#a29`

## why

Edit live. No installation or config. Mobile friendly.

## what.svg
```svg
<svg width="100%">
<text x="10" y="50" font-size="1.8rem" fill="{{ colors.blue }}" stroke="{{ colors.blue_darker }}" stroke-dasharray="6 2">
{{ what }}
</text>
</svg>
```

## why.svg
```svg
<svg width="100%">
<text x="10" y="50" font-size="1.8rem" fill="{{ colors.pink }}" stroke="{{ colors.pink_darker }}" stroke-dasharray="6 2">
{{ why }}
</text>
</svg>
```
"""
