---
sidebar_position: 5
---

# Credits

Vetra is built and maintained by **VeDevelopment**.

---

## Author

Vetra was designed, written, and is actively maintained by the VeDevelopment team. Every line —
the analytic kinematics engine, the parallel Actor architecture, the VetraNet middleware, the
corner-trap detector, the G-series drag tables, the benchmarker, is original work.

**Find us:**

- [Discord Server](https://discord.gg/XMYMRKcd3g)
- [Direct Message](https://discord.com/users/897026279243669504)
- [Instagram](https://www.instagram.com/vedevelopment/)
- [X / Twitter](https://x.com/vedevelopment_)
- [TikTok](https://www.tiktok.com/@vedevelopment)

---

## Dependencies

Vetra ships with one internal dependency:

**VeSignal**, a high-performance, type-safe signal implementation for Roblox Luau, written by
VeDevelopment. It uses connection pooling, scratch arrays, and thread recycling to minimise GC
pressure. Its `FireSafe` path is used throughout the solver for user-facing signal emissions where
error isolation matters.

---

## License

Vetra is released under the **MIT License**.

```
MIT License
Copyright (c) 2026 VeDevelopment

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```