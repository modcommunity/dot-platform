# dot-platform

Joins dot-auth, dot-user and dot-user-avatar into one admission flow and binds it to a dot-server; `DotPlatformIdentity` is the identity layer every game builds on. Its examples are the only place the family's addons run together.

Read the family [CLAUDE.md](../../CLAUDE.md) first, then [PLATFORM.md](../../PLATFORM.md), the design this implements. This file is only what is specific to dot-platform.

**The distributable is `addons/dot_platform/`.** Every other addon is symlinked in and in `.gitignore`. Create the links before validating:

```bash
for a in dot_core:dot-core dot_auth:dot-auth dot_user:dot-user \
         dot_user_avatar:dot-user-avatar dot_server:dot-server dot_cloud:dot-cloud \
         dot_net:dot-net dot_player:dot-player dot_player_controller:dot-player-controller; do
    ln -sfn "../../${a##*:}/addons/${a%%:*}" "addons/${a%%:*}"
done
```

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the one translation, what is optional, admission gating the spawn, the three events, the identity layer, two multiplayer APIs in one process, what is not here |
| [docs/history.md](docs/history.md) | the join bugs, the class-name collision, and the avatar bugs |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_platform/dot_platform.gd` | `DotPlatformHub`: the uid to scoped-key translation, admission |
| `addons/dot_platform/dot_platform_player.gd` | `DotPlatformPlayer`: one admitted player; `account_uid()` |
| `addons/dot_platform/dot_platform_module.gd` | `DotPlatformModule`: the dot-server module; holds the PROFILE stage while admission runs, the late path, the three server events |
| `addons/dot_platform/dot_platform_identity.gd` | `DotPlatformIdentity`: the identity layer a game subclasses or returns from dot-game's `_make_identity()` |
| `addons/dot_platform/dot_platform_config.gd` | `DotPlatformConfig` |
| `addons/dot_platform/dot_platform_api.gd` | the API `LEVEL` and `OLDEST` a game checks |
| `examples/seam_selftest.tscn` | every handoff, with real managers; one section per seam |
| `examples/sandbox_server.tscn` | a real server and client in one process, on port 27077 |

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), parsing only this repository's scripts (`-not -path './addons/dot_*/*'` on the `find`), then `res://examples/seam_selftest.tscn` and `res://examples/sandbox_server.tscn`.

`sandbox_server` binds a real port (27077): a failure there is as likely to be the environment as the code. It fails rather than hangs, with the client's phase in the message.

## Rules that bite

- Only `DotPlatformHub` translates `identity.uid` to the scoped `user_key`; the avatar is keyed on the scoped key, never the uid. [design](docs/design.md#the-one-translation)
- Never store, log or send `account_uid()`. [design](docs/design.md#the-one-translation)
- Managers come from `DotRegistry`; every absent addon has a defined answer, covered by the "absent addons" section. [design](docs/design.md#everything-optional-stays-optional)
- The module holds dot-server's PROFILE stage while admission runs, taking the hold synchronously inside `client_state_changed`; a required admission refuses there (`refuse_profile`), an optional one is let in after `admission_timeout_sec`. [design](docs/design.md#admission-gates-the-spawn)
- Reach dot-server's stage API through `has_method`/`call`, so the module still parses on a dot-server older than the stage and admits late there. [design](docs/design.md#admission-gates-the-spawn)
- Admission can still finish after the spawn (the late path); a game redraws on `player_admitted`, `player_renamed` and `player_avatar_changed`. dot-platform sends nothing to a client. [design](docs/design.md#three-server-events-tell-the-game-when-to-redraw)
- A suite of the hold needs a store that suspends; one that answers at once passes with the hold removed. [design](docs/design.md#admission-gates-the-spawn)
- A game hands `DotPlatformIdentity` an `avatar_schema` and a `stock_avatar_fn`; `avatar_for` is never null while there is a schema. [design](docs/design.md#a-games-identity-layer-is-dotplatformidentity)
- `DotPlatformModule` must keep returning when its hub is no longer valid. [design](docs/design.md#a-module-whose-hub-was-freed-admits-nobody)
- Two multiplayer APIs in one tree: RPC routing is the node path under each root, so the client link is named `Server`. [design](docs/design.md#two-multiplayerapi-instances-in-one-process)
- Check a new `class_name` against every addon in the family (`DotPlatform` is dot-core's). [history](docs/history.md#a-class-name-that-broke-dot-core)
- Add a case to `seam_selftest` for any change to a handoff: it is the only test that runs more than one of these addons at once.
- Raise `LEVEL` in `dot_platform_api.gd` for anything new a game could call. [dot_platform_api.gd](addons/dot_platform/dot_platform_api.gd)

Deliberately not here: a game, the avatar editor UI, matchmaking and discovery. [design](docs/design.md#deliberately-not-here)
