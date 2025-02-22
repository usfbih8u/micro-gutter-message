# Micro Gutter Message

Navigate through the BufPane gutter messages and display them in a tooltip.

## ❓ How to use it

Insert in the command bar `> gutter_message` and hit `ENTER`; by default, the plugin will go to the next message.

### Options

> Use tab to **autocomplete plugin options**.

- `next`: Go to the next message from the current location.
- `prev`: Go to the previous message from the current location.
- `dnext`: Go to the next message from the current location and display the tooltip.
- `dprev`: Go to the previous message from the current location and display the tooltip.
- `display`: Display the tooltip.

## 🎨 Syntax and Colorscheme

To improve readability, a custom syntax and colorscheme are provided until Micro allows customization of colorschemes per buffer.

You can add the following line at the end of your current colorscheme: `include gutter-message`. **I recommend using a custom colorscheme** that includes both your main colorscheme and this one.

```
# custom-colorscheme.micro
include "YOUR_MAIN_COLORSCHEME"
include "gutter-message"
include "autocomplete-tooltip" # 👀
```

You can **change the colors** inside `colorschemes/gutter-message.micro`.

## 📦 Installation

**Do NOT change the name of the plugin directory `micro-gutter-message`**.  It is used as a prefix to avoid path collisions in `package.path` when requiring modules.

In Linux, you can clone the repo anywhere and create a symlink inside `.config/micro/plug` using the `ENABLE_FOR_MICRO.sh` script.
