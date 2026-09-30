class_name CombatProfile
extends Resource
## Every value that shapes how melee feels. Shared by the player and enemies so both
## play by the same rules. Edit it in the Inspector, or live in-game with F1.

@export_group("Global")
## Scales every combat timing. Below 1 = slower, heavier fights.
@export_range(0.25, 2.0, 0.05) var combat_speed := 1.0

@export_group("Windup")
## Time to draw the weapon fully back.
@export_range(0.1, 1.5, 0.01) var windup_time := 0.5
## Earliest a swing can be released after starting the windup.
@export_range(0.05, 1.5, 0.01) var min_windup := 0.35
## Holding this long gives full damage.
@export_range(0.2, 3.0, 0.05) var full_charge_time := 1.1
## Damage multiplier of a minimum-charge swing.
@export_range(0.0, 1.0, 0.01) var charge_min_damage := 0.7
## How far back the weapon is drawn. 1 = default pose, higher = bigger backswing.
@export_range(0.3, 2.0, 0.05) var backswing_amount := 1.0
## Windup easing. Higher = snaps back quickly, then settles slowly.
@export_range(1.0, 4.0, 0.1) var windup_ease := 2.0

@export_group("Swing")
## Brief extra pull-back right before the strike (the "cock" of the swing).
@export_range(0.0, 0.3, 0.01) var anticipation_time := 0.08
@export_range(0.0, 0.6, 0.01) var anticipation_amount := 0.15
## Swing easing. Higher = slow start and a fast, heavy finish.
@export_range(1.0, 4.0, 0.1) var swing_ease := 2.0
## Forward step speed during the strike (m/s).
@export_range(0.0, 6.0, 0.1) var swing_lunge := 1.5
## On a miss, the weapon keeps travelling past the end pose.
@export_range(0.0, 0.8, 0.01) var follow_through_time := 0.3
@export_range(0.0, 1.0, 0.05) var follow_through_amount := 0.35
## Time to return to guard after a swing. You can't act during it.
@export_range(0.05, 1.5, 0.01) var recover_time := 0.4

@export_group("Impact")
## Freeze frames when a swing hits flesh.
@export_range(0.0, 0.3, 0.005) var hit_stop := 0.08
## How far the weapon rebounds toward the backswing after a hit.
@export_range(0.0, 1.0, 0.05) var hit_bounce_amount := 0.35
@export_range(0.05, 1.0, 0.01) var hit_bounce_time := 0.25
## If on, the swing cuts through the target instead of bouncing off.
@export var hit_passes_through := false
## Freeze frames when a swing is blocked.
@export_range(0.0, 0.3, 0.005) var block_stop := 0.12
@export_range(0.0, 1.0, 0.05) var block_bounce_amount := 0.6
@export_range(0.05, 1.0, 0.01) var block_bounce_time := 0.35
## Extra time the attacker is locked after being blocked.
@export_range(0.0, 1.5, 0.05) var blocked_recoil := 0.4
## Swings bounce off walls and props.
@export var world_collision := true
@export_range(0.0, 1.0, 0.05) var world_bounce_amount := 0.5
## How hard a hit pushes the target (m/s).
@export_range(0.0, 6.0, 0.1) var hit_knockback := 2.5

@export_group("Defense")
## A block raised this recently when hit counts as a parry.
@export_range(0.0, 0.6, 0.01) var parry_window := 0.2
@export_range(0.0, 2.5, 0.05) var parry_stagger := 1.0
## Stagger from taking a hit. It interrupts windups and blocks.
@export_range(0.0, 1.0, 0.01) var flinch_time := 0.35
@export_range(0.0, 2.5, 0.05) var guard_break_stagger := 1.0
## Time to move the weapon into a block pose (visual only; blocks work immediately).
@export_range(0.03, 0.5, 0.01) var block_raise_time := 0.15
## Stamina lost per point of blocked damage.
@export_range(0.0, 2.0, 0.05) var block_cost_ratio := 0.8

@export_group("Stamina")
@export_range(0.0, 80.0, 1.0) var stamina_regen := 25.0
@export_range(0.0, 3.0, 0.05) var regen_delay := 0.8
@export_range(0.0, 40.0, 1.0) var feint_cost := 8.0

@export_group("Movement & turning")
@export_range(0.0, 1.0, 0.05) var windup_move := 0.6
@export_range(0.0, 1.0, 0.05) var swing_move := 0.35
@export_range(0.0, 1.0, 0.05) var block_move := 0.55
## Max turn speed while winding up (deg/s). 0 = no limit.
@export_range(0.0, 720.0, 10.0) var windup_turn_cap := 360.0
## Max turn speed while swinging (deg/s). 0 = no limit. Stops 180° mouse flicks.
@export_range(0.0, 720.0, 10.0) var swing_turn_cap := 150.0

@export_group("Camera (player)")
## Camera roll/pitch that follows your swing (degrees).
@export_range(0.0, 10.0, 0.1) var swing_camera_roll := 2.5
@export_range(0.0, 0.3, 0.005) var hit_camera_shake := 0.05
@export_range(0.0, 0.3, 0.005) var block_camera_shake := 0.03

@export_group("Reach")
@export_range(1.0, 4.0, 0.05) var reach := 2.3

@export_group("Overhead")
@export_range(0.1, 1.5, 0.01) var overhead_duration := 0.55
## Point in the swing motion (0-1) where the hit lands.
@export_range(0.1, 1.0, 0.01) var overhead_impact := 0.8
@export_range(0.1, 3.0, 0.05) var overhead_damage := 1.25
@export_range(0.0, 1.5, 0.05) var overhead_reach := 0.0
@export_range(5.0, 180.0, 1.0) var overhead_arc := 40.0
@export_range(0.0, 50.0, 1.0) var overhead_stamina := 18.0

@export_group("Thrust")
@export_range(0.1, 1.5, 0.01) var thrust_duration := 0.42
@export_range(0.1, 1.0, 0.01) var thrust_impact := 0.65
@export_range(0.1, 3.0, 0.05) var thrust_damage := 0.85
@export_range(0.0, 1.5, 0.05) var thrust_reach := 0.5
@export_range(5.0, 180.0, 1.0) var thrust_arc := 25.0
@export_range(0.0, 50.0, 1.0) var thrust_stamina := 12.0

@export_group("Side swings")
@export_range(0.1, 1.5, 0.01) var side_duration := 0.5
@export_range(0.1, 1.0, 0.01) var side_impact := 0.6
@export_range(0.1, 3.0, 0.05) var side_damage := 1.0
@export_range(0.0, 1.5, 0.05) var side_reach := 0.0
@export_range(5.0, 180.0, 1.0) var side_arc := 80.0
@export_range(0.0, 50.0, 1.0) var side_stamina := 15.0
## Side swings can hit several enemies in their arc.
@export var side_cleave := true


## Stats for one attack direction (0 overhead, 1 thrust, 2/3 sides; matches MeleeCombat.Dir).
func attack(dir: int) -> Dictionary:
	match dir:
		0:
			return {"duration": overhead_duration, "impact": overhead_impact, "damage": overhead_damage,
				"reach": overhead_reach, "arc": overhead_arc, "stamina": overhead_stamina, "cleave": false}
		1:
			return {"duration": thrust_duration, "impact": thrust_impact, "damage": thrust_damage,
				"reach": thrust_reach, "arc": thrust_arc, "stamina": thrust_stamina, "cleave": false}
	return {"duration": side_duration, "impact": side_impact, "damage": side_damage,
		"reach": side_reach, "arc": side_arc, "stamina": side_stamina, "cleave": side_cleave}
