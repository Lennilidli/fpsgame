# Assets

Everything here is CC0 (public domain): free for any use, including commercial, with no
attribution required.

| Folder | Content | Source |
|---|---|---|
| `textures/Ground037` | Grass and earth ground | [ambientCG](https://ambientcg.com/view?id=Ground037) |
| `textures/PavingStones141` | Medieval cobblestone | [ambientCG](https://ambientcg.com/view?id=PavingStones141) |
| `textures/Rock063` | Aged stone (walls, pillars) | [ambientCG](https://ambientcg.com/view?id=Rock063) |
| `textures/Planks039` | Rough medieval planks | [ambientCG](https://ambientcg.com/view?id=Planks039) |
| `textures/Metal038` | Scratched steel (armour, blade) | [ambientCG](https://ambientcg.com/view?id=Metal038) |
| `textures/Chainmail002` | Chainmail | [ambientCG](https://ambientcg.com/view?id=Chainmail002) |
| `textures/Leather030` | Leather (grip, belt) | [ambientCG](https://ambientcg.com/view?id=Leather030) |
| `sky/sky_partly_cloudy_2k.hdr` | HDRI sky (background + lighting) | [Poly Haven: kloofendal_48d_partly_cloudy_puresky](https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky) |

Generated in this project:

- `sword/blade_mesh.tres`: longsword blade, from `tools/generate_sword_mesh.gd`.
- The knights (`scripts/knight_rig.gd`) and first-person arms (`scripts/fp_arms.gd`) are
  built from primitive meshes at runtime.

## Swapping in a real character model later

The knight rig only reads the sword's position and places the body around it, so a
skinned humanoid (e.g. from Mixamo) can replace it later without touching combat code:
hands to the sword's grip via IK, legs from walk/strafe animations.
