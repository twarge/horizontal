# Horizon pool items shipped with Horizontal

Everything in this directory except this README is from the
[Horizon pool](https://github.com/horizon-eda/horizon-pool), compiled by the
Horizon community, and is redistributed here unchanged, byte for byte:

| File | Pool item | uuid | Authors |
| --- | --- | --- | --- |
| `padstacks/via-round-tented.json` | Circular via (tented) | `8b6dee4b-af88-4c0f-b38b-c5364649e65e` | Lukas K., fruchti |
| `padstacks/via-round.json` | Circular via | `3c4a52fe-3ae0-4c3e-a108-824b53d6d6da` | Lukas K. |
| `LICENSE.md` | the Horizon pool's licence | | |

They are copied from horizon-pool at commit
[`0cd2d0b0`](https://github.com/horizon-eda/horizon-pool/commit/0cd2d0b02634320dffabbc03355687c37eb507cf)
("Add tented vias", 2019-06-20), the last commit to change either padstack, and
keep the paths and uuids they have there, so a board that names one names the
same item horizon-pool has.

## Licence

These files are licensed under the
[Creative Commons Attribution-ShareAlike 4.0 International licence](https://creativecommons.org/licenses/by-sa/4.0/legalcode)
(CC BY-SA 4.0), with the exception for designs set out in `LICENSE.md`: a design
that uses them, and the files generated from it, are not bound by that licence.
Redistributed, as they are here, they stay under it.

That licence is the Horizon pool's. Horizontal's own code is under the Apache
License 2.0; none of it is in this directory, and none of these files is under
the Apache License.

The Horizon pool is provided without warranty of any kind, express or implied.

## Why Horizontal carries them

Horizon gives a new board a via rule with its pool's default via, and
Horizontal gives it that via tented. With no pool installed, no pool names a
via, so Horizontal ships these two, under their own uuids, and copies the one a
board uses into the project's pool cache, as Horizon copies an item it takes
from a pool. The project then carries the padstack itself, and opens in Horizon
on a machine without horizon-pool.
