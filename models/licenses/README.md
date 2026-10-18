# Licence texts

The canonical text of each licence a catalogue model may have. `scripts/models.py` appends the right one to every model's `NOTICE.txt`, since several model repositories ship no licence file of their own. Only these licences pass the catalogue's allowlist.

| File | Licence | Source |
|---|---|---|
| `Apache-2.0.txt` | Apache License 2.0 | https://www.apache.org/licenses/LICENSE-2.0.txt |
| `CC-BY-4.0.txt` | Creative Commons Attribution 4.0 International | https://creativecommons.org/licenses/by/4.0/legalcode.txt |
| `MIT.txt` | MIT License; `{copyright}` is replaced with the model's copyright line from the catalogue | https://opensource.org/license/mit (identical to Silero VAD's `LICENSE` below the copyright line) |
| `OpenMDW-1.1.txt` | OpenMDW License Agreement 1.1 | https://github.com/OpenMDW/OpenMDW/blob/b26b32b34ad2edcc29a7707abb68dcfb25a538c1/1.1/LICENSE.OpenMDW-1.1 |

OpenMDW-1.1 has a termination clause: the rights end for anyone who sues claiming the model infringes a patent or copyright, unless they were sued first. Hugging Face tags OpenMDW models `other` and names the licence in `license_name`, so the allowlist reads `license_name` when the tag is `other`.
