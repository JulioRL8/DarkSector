// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @notice Lifecycle of a game: waiting for an opponent, active, or permanently finished.
enum GameStatus {
    WaitingForPlayer,
    Active,
    Finished
}

/// @notice Terrain categories; Empty is the zero value used for unassigned map cells.
enum SectorType {
    Empty,
    Obstacle,
    EnergyStation,
    Base,
    CentralCore
}

/// @notice Stored outcome; Pending remains set until normal completion or forfeiture.
enum GameResult {
    Pending,
    PlayerAWins,
    PlayerBWins,
    Draw
}

/// @notice Participant identity and accumulated energy and points.
struct Player {
    address account;
    uint32 energy;
    uint32 points;
}

/// @notice Single fleet per player; zero ships means destroyed and position is its base reference.
struct Fleet {
    uint8 position;
    uint8 ships;
}

/// @notice Per-game lifecycle, player resources, fleets, result and current phase deadline.
struct Game {
    GameStatus status;
    uint8 round;
    Player playerA;
    Player playerB;
    Fleet fleetA;
    Fleet fleetB;
    GameResult result;
    RoundPhase phase;
    uint256 phaseDeadline;
}

/// @notice Order actions; existing numeric values must remain stable for commitment encoding.
enum ActionType {
    Hold,
    Move, 
    Capture,
    Defend,
    Build
}

/// @notice An action and its original destination; only Move interprets destination as a target.
struct Order {
    ActionType action;
    uint8 destination;
}

/// @notice Commit locks order hashes; Reveal opens the committed orders before resolution.
enum RoundPhase {
    Commit,
    Reveal
}

/// @notice One participant's pending order hash and per-round commit/reveal flags.
struct OrderCommitment {
    bytes32 commitment;
    bool committed;
    bool revealed;
}

/// @notice Original positions and movement intentions used to resolve a simultaneous encounter.
struct CombatContext {
    uint8 originA;
    uint8 originB;
    uint8 targetA;
    uint8 targetB;
    bool movingA;
    bool movingB;
    bool swapping;
}

/// @title Dark Sector
/// @notice A two-player, ten-round space strategy game with simultaneous committed orders.
/// @dev Uses deterministic combat, persistent territory income and permissionless timeout
///      recovery. Games are independent entries keyed by ID. Clients generate commitments
///      off-chain and retain their secrets; private mappings do not make chain data secret.
contract DarkSector {
    /// @dev Board width and height. The fixed scenario assumes five.
    uint dimension = 5;
    /// @dev Next unused game ID; IDs below this value exist.
    uint256 currentGameId = 0;
    /// @dev Last playable round, including its income and scoring.
    uint256 constant maxRound = 10;

    /// @dev Independent game states indexed by creation ID.
    mapping(uint256 => Game) games;
    /// @dev Terrain arrays initialized when the second player joins.
    mapping(uint256 => SectorType[]) maps;

    /// @dev Persistent sector control; address(0) denotes an unclaimed sector.
    mapping(uint256 => mapping(uint8 => address)) 
        internal sectorOwners;
    /// @dev Validated effective orders awaiting simultaneous resolution.
    mapping(uint256 => mapping(address => Order)) 
        internal orders;
    /// @dev Per-game participant commitments, cleared when a round closes.
    mapping(uint256 => mapping(address => OrderCommitment))
        internal commitments;

    /// @notice Accumulated reveal faults for a participant in a game.
    /// @dev Two faults cause forfeiture. Counts persist across rounds and after game completion;
    ///      the generated getter returns zero for entries that have never been written.
    mapping(uint256 => mapping(address => uint8))
        public revealFaults;

    /// @dev Duration used for both Commit and Reveal windows.
    uint256 constant revealTime = 5 minutes;

    // Errors
    /// @notice The creator attempted to occupy the second player slot in their own game.
    error InvalidAddress();
    /// @notice The game, phase or reveal state does not permit the requested operation.
    error InvalidStatus();
    /// @notice The caller is not a participant authorized for the requested player action.
    error Forbidden();
    /// @notice The caller has already submitted a commitment for the current round.
    error AlreadyReady();
    /// @notice The requested game ID has not been created.
    error GameDoesNotExists();
    /// @notice Legacy action-validation error; the current reveal flow converts illegal orders to Hold instead.
    error IncorrectMove();
    /// @notice A commit or reveal was submitted at or after its phase deadline.
    error DeadlineReached();
    /// @notice The revealed order and salt do not reproduce the stored commitment.
    error HashNotValid();
    /// @notice Timeout recovery was requested before the current phase deadline.
    error DeadlineNotReached();

    // Events 
    /// @notice Emitted when a waiting game is registered.
    /// @param gameId Identifier assigned to the new game.
    /// @param creator Address occupying player A's slot.
    event GameCreated(uint256 indexed gameId, address indexed creator);
    /// @notice Emitted when player B joins and the game becomes active.
    /// @param gameId Identifier of the started game.
    /// @param playerA Address of the creator.
    /// @param playerB Address of the joining participant.
    event GameStarted(
        uint256 indexed gameId,
        address indexed playerA,
        address indexed playerB
    );
    /// @notice Legacy readiness event retained in the ABI; not emitted by the commit-reveal flow.
    /// @param gameId Identifier of the game.
    /// @param player Address of the participant.
    event PlayerReady(uint256 indexed gameId, address indexed player);
    /// @notice Emitted after a normal round's actions and income have been applied.
    /// @param gameId Identifier of the resolved game.
    /// @param round Number of the round just completed, before any increment.
    event RoundResolved(uint256 indexed gameId, uint8 round);
    /// @notice Emitted after normal completion or forfeiture marks a game as finished.
    /// @param gameId Identifier of the finished game.
    event GameFinished(uint256 indexed gameId); 
    /// @notice Emitted when a living fleet actually changes position.
    /// @dev Destruction resets and unsuccessful exchanges do not emit movement events.
    /// @param gameId Identifier of the game.
    /// @param user Address controlling the moving fleet.
    /// @param origin Sector occupied before movement.
    /// @param destination Sector occupied after resolution.
    event FleetMoved(
        uint256 gameId, 
        address indexed user, 
        uint256 origin, 
        uint256 destination
    );
    /// @notice Emitted when a surviving Capture order transfers sector control.
    /// @param gameId Identifier of the game.
    /// @param position Index of the captured station or core.
    /// @param previousOwner Prior owner, or address(0) for an unclaimed sector.
    /// @param newOwner Address of the capturing participant.
    event SectorCaptured(
        uint256 gameId,
        uint8 position,
        address indexed previousOwner,
        address indexed newOwner
    );
    /// @notice Emitted with the stored result and accumulated scores when a game ends.
    /// @dev Forfeiture may determine the winner independently of the point totals.
    /// @param gameId Identifier of the game.
    /// @param result Final winner or draw.
    /// @param pointsA Player A's accumulated points.
    /// @param pointsB Player B's accumulated points.
    event GameResultDeclared(
        uint256 indexed gameId,
        GameResult result,
        uint32 pointsA,
        uint32 pointsB
    );
    /// @notice Emitted with simultaneous casualties before fleet state is updated.
    /// @param gameId Identifier of the game.
    /// @param originA Player A's position before the encounter.
    /// @param originB Player B's position before the encounter.
    /// @param targetA Player A's proposed destination, not necessarily the final position.
    /// @param targetB Player B's proposed destination, not necessarily the final position.
    /// @param lossesA Number of player A's ships destroyed.
    /// @param lossesB Number of player B's ships destroyed.
    event CombatResolved(
        uint256 indexed gameId,
        uint8 originA,
        uint8 originB,
        uint8 targetA,
        uint8 targetB,
        uint8 lossesA,
        uint8 lossesB
    );
    /// @notice Emitted when combat reduces a living fleet to zero ships.
    /// @param gameId Identifier of the game.
    /// @param player Address whose fleet was destroyed.
    event FleetDestroyed(
        uint256 indexed gameId,
        address indexed player
    );
    /// @notice Emitted after a Build order pays its cost and adds one ship.
    /// @param gameId Identifier of the game.
    /// @param player Address building or rebuilding its fleet.
    /// @param totalShips Number of ships in that fleet after construction.
    event ShipBuilt(
        uint256 indexed gameId,
        address indexed player,
        uint8 totalShips
    );

    /// @notice Deploys the game contract without creating or starting a game.
    /// @dev Individual games are initialized explicitly through createGame and joinGame.
    constructor() { }

    /// @notice Creates a waiting game with the caller as player A.
    /// @dev Assigns a unique, zero-based ID, five energy and three ships per player slot,
    ///      and round one. The map is initialized and the commit deadline is renewed on join.
    ///      Emits GameCreated. Does not require a payment or start gameplay.
    /// @return gameId Identifier of the newly created game.
    function createGame() external returns(uint256 gameId) {
        games[currentGameId] = Game({
            status: GameStatus.WaitingForPlayer,
            round: 1,
            playerA: Player({ 
                account: msg.sender,
                energy: 5,
                points: 0
            }),
            playerB: Player({ 
                account: address(0),
                energy: 5,
                points: 0
            }),
            fleetA: Fleet({position: 0, ships: 3}),
            fleetB: Fleet({
                position: uint8(dimension * dimension) - 1, 
                ships: 3
            }),
            result: GameResult.Pending, 
            phase: RoundPhase.Commit,
            phaseDeadline: block.timestamp + revealTime
        });
        gameId = currentGameId;
        currentGameId++;

        emit GameCreated(gameId, msg.sender);
    }

    /// @notice Joins a waiting game as player B and starts its first commit phase.
    /// @dev Reverts for an unknown game, a game that is not waiting, or the creator joining
    ///      their own game. Initializes the fixed map and a fresh five-minute deadline.
    ///      Emits GameStarted.
    /// @param gameId Identifier of the game to join.
    function joinGame(uint256 gameId) external {
        require(gameId < currentGameId, GameDoesNotExists());

        Game storage game = games[gameId];
        require(game.status == GameStatus.WaitingForPlayer, InvalidStatus());
        require(game.playerA.account != msg.sender, InvalidAddress());
        
        game.playerB.account = msg.sender;
        game.status = GameStatus.Active;
        maps[gameId] = initializeScenario();
        game.phaseDeadline = block.timestamp + revealTime;

        emit GameStarted(gameId, game.playerA.account, msg.sender);
    }

    /// @notice Returns the stored state of an existing game.
    /// @dev Includes players, fleets, round, phase, deadline and result. Pending commitments
    ///      and orders are not included. Reverts if the game does not exist.
    /// @param gameId Identifier of the game to inspect.
    /// @return The game state copied into memory.
    function getGame(uint256 gameId) external view
        returns (Game memory) {
        require(gameId < currentGameId, GameDoesNotExists());
        
        return games[gameId];
    }

    /// @notice Returns the terrain type at a position in a game's initialized map.
    /// @dev Reverts for an unknown game or an out-of-bounds array index. The map is empty
    ///      before a second player joins, so terrain cannot be queried during that period.
    /// @param position Zero-based sector index; valid initialized positions are 0 through 24.
    /// @param gameId Identifier of the game whose map is queried.
    /// @return The terrain type at the requested position.
    function getSectorType(uint8 position, uint256 gameId) external view
        returns (SectorType) {
        require(gameId < currentGameId, GameDoesNotExists());
        
        return maps[gameId][position];
    }

    /// @notice Locks the caller's order hash for the current round.
    /// @dev Only a participant in an active game may commit, once per round, during Commit
    ///      and strictly before the deadline. Both commitments open Reveal with a fresh deadline.
    ///      The expected hash is keccak256(abi.encode(address(this), block.chainid, gameId,
    ///      game.round, msg.sender, action, destination, salt)); clients must use the same types.
    ///      Use an unpredictable salt and retain the original order and salt until revelation.
    ///      The committed flag records participation independently of the hash value.
    /// @param gameId Identifier of the active game.
    /// @param commitment Hash binding the order and salt to this execution context.
    function commitOrders(uint256 gameId, bytes32 commitment) external {
        require(gameId < currentGameId, GameDoesNotExists());

        Game storage game = games[gameId];

        require(game.status == GameStatus.Active, InvalidStatus());
        require(game.playerA.account == msg.sender || game.playerB.account == msg.sender, Forbidden());
        require(game.phase == RoundPhase.Commit, InvalidStatus());
        require(game.phaseDeadline > block.timestamp, DeadlineReached());
        require(!commitments[gameId][msg.sender].committed, AlreadyReady());


        commitments[gameId][msg.sender] = OrderCommitment({
            commitment: commitment,
            committed: true,
            revealed: false
        });

        address otherPlayer = msg.sender == game.playerA.account 
            ? game.playerB.account 
            : game.playerA.account;

        if (commitments[gameId][otherPlayer].committed) {
            game.phase = RoundPhase.Reveal;
            game.phaseDeadline = block.timestamp + revealTime;
        }
    }

    /// @notice Reveals the caller's committed order and resolves the round when all required reveals are available.
    /// @dev Requires an active game, Reveal phase, an unrevealed commitment, and an open
    ///      deadline. A mismatching hash reverts without deleting the commitment. A matching
    ///      but illegal order is recorded as Hold. No action executes on the first reveal
    ///      if the other participant still owes a reveal. A participant who never committed
    ///      does not owe a reveal after commit-timeout recovery.
    /// @param gameId Identifier of the active game.
    /// @param action Action originally included in the commitment.
    /// @param destination Original uint8 destination; affects movement only but is always hashed.
    /// @param salt Original secret used to construct the commitment.
    function revealOrders(
        uint256 gameId,
        ActionType action,
        uint8 destination,
        bytes32 salt
    ) external {
        require(gameId < currentGameId, GameDoesNotExists());

        Game storage game = games[gameId];

        require(game.status == GameStatus.Active, InvalidStatus());
        require(game.phase == RoundPhase.Reveal, InvalidStatus());

        OrderCommitment storage commit = commitments[gameId][msg.sender];  
        require(commit.committed, InvalidStatus());
        require(!commit.revealed, InvalidStatus());
        require(game.phaseDeadline > block.timestamp, DeadlineReached());

        bytes32 calculatedCommitment = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                gameId,
                game.round,
                msg.sender,
                action,
                destination,
                salt
            )
        );

        require(
            calculatedCommitment ==
                commitments[gameId][msg.sender].commitment,
            HashNotValid()
        );

        Player storage player;
        Fleet storage fleet;
        if (game.playerA.account == msg.sender) {
            player = game.playerA;
            fleet = game.fleetA;
        } else if (game.playerB.account == msg.sender) {
            player = game.playerB;
            fleet = game.fleetB;
        } else {
            revert Forbidden();
        }

        orders[gameId][msg.sender] = _resolveAction(gameId, player, fleet, action, destination);
        commit.revealed = true;

        Player memory otherPlayer = msg.sender == game.playerA.account ? game.playerB : game.playerA;
        OrderCommitment memory otherPlayerCommit = commitments[gameId][otherPlayer.account];

        if (otherPlayerCommit.revealed || !otherPlayerCommit.committed) {
            _finishRound(gameId);
        }
    }

    /// @notice Returns the address controlling a sector, or address(0) if it is unclaimed.
    /// @dev Control persists when a fleet leaves or is destroyed. Reverts for an unknown
    ///      game or a position outside the initialized map, including queries before join.
    /// @param gameId Identifier of the game to inspect.
    /// @param position Zero-based sector index within the initialized map.
    /// @return Address of the controlling player, or the zero address for unclaimed sectors.
    function getSectorOwner(
        uint256 gameId,
        uint8 position
    ) external view returns (address) {
        require(gameId < currentGameId, GameDoesNotExists());
        require(position < maps[gameId].length);
        return sectorOwners[gameId][position];
    }

    /// @notice Advances an expired phase or ends the game after repeated reveal faults.
    /// @dev Callable by anyone for an active game at or after phaseDeadline. With no commits,
    ///      resolves both players as Hold. With one commit, opens a fresh Reveal window.
    ///      During Reveal, committed players who did not reveal receive a fault and Hold.
    ///      Two accumulated reveal faults cause forfeiture; simultaneous forfeitures draw.
    ///      Forfeiture clears pending data and emits final events without actions or income.
    ///      Otherwise the round closes normally. Time passing alone does not execute this call.
    /// @param gameId Identifier of the game whose deadline has expired.
    function advanceAfterTimeout(uint256 gameId) external {
        require(gameId < currentGameId, GameDoesNotExists());

        Game storage game = games[gameId];

        require(game.status == GameStatus.Active, InvalidStatus());
        require(
            block.timestamp >= game.phaseDeadline,
            DeadlineNotReached()
        );

        OrderCommitment memory commitA =
                commitments[gameId][game.playerA.account];

        OrderCommitment memory commitB =
                commitments[gameId][game.playerB.account];

        if (game.phase == RoundPhase.Commit) {
            bool committedA = commitA.committed;

            bool committedB = commitB.committed;

            if (!committedA && !committedB) {
                _finishRound(gameId);
            } else {
                game.phase = RoundPhase.Reveal;
                game.phaseDeadline = block.timestamp + revealTime;
            }

            return;
        } else if (game.phase == RoundPhase.Reveal) {
            bool missingA = commitA.committed && !commitA.revealed;
            bool missingB = commitB.committed && !commitB.revealed;

            if (missingA) {
                revealFaults[gameId][game.playerA.account]++;

                orders[gameId][game.playerA.account] = Order({
                    action: ActionType.Hold,
                    destination: 0
                });
            }

            if (missingB) {
                revealFaults[gameId][game.playerB.account]++;

                orders[gameId][game.playerB.account] = Order({
                    action: ActionType.Hold,
                    destination: 0
                });
            }

            bool losesA =
                revealFaults[gameId][game.playerA.account] >= 2;

            bool losesB =
                revealFaults[gameId][game.playerB.account] >= 2;

            if (losesA || losesB) {
                if (losesA && losesB) {
                    game.result = GameResult.Draw;
                } else if (losesA) {
                    game.result = GameResult.PlayerBWins;
                } else {
                    game.result = GameResult.PlayerAWins;
                }

                game.status = GameStatus.Finished;

                delete orders[gameId][game.playerA.account];
                delete orders[gameId][game.playerB.account];
                delete commitments[gameId][game.playerA.account];
                delete commitments[gameId][game.playerB.account];

                emit GameResultDeclared(
                    gameId,
                    game.result,
                    game.playerA.points,
                    game.playerB.points
                );

                emit GameFinished(gameId);
                return;
            }

            _finishRound(gameId);
        }
    }

    // Internal

    /// @notice Resolves one round and either opens the next commit phase or finishes the game.
    /// @dev Call only after all required reveals or timeout defaults are ready. Includes
    ///      round-ten income before calculating the result. Emits RoundResolved before
    ///      incrementing the round; the final round remains numbered ten.
    /// @param gameId Identifier of the active game whose round is ready to close.
    function _finishRound(uint256 gameId) internal {
        Game storage game = games[gameId];

        _resolveRound(gameId);

        emit RoundResolved(gameId, game.round);

        if (game.round == maxRound) {
            _checkResult(gameId);
            game.status = GameStatus.Finished;

            emit GameResultDeclared(
                gameId,
                game.result,
                game.playerA.points,
                game.playerB.points
            );

            emit GameFinished(gameId);
        } else {
            game.round++;
            game.phase = RoundPhase.Commit;
            game.phaseDeadline = block.timestamp + revealTime;
        }
    }

    /// @notice Applies the ordered gameplay effects and clears pending round data.
    /// @dev Resolves movement/combat, surviving captures, construction, then income/points.
    ///      Deletes both players' orders and commitments, but preserves cumulative reveal faults.
    ///      Does not itself change the round number, phase, deadline or final result.
    /// @param gameId Identifier of the game to resolve.
    function _resolveRound(uint256 gameId) internal {
        Game storage game = games[gameId];

        _resolveMovementAndCombat(gameId);
        _resolveCaptures(gameId);
        _resolveBuilds(gameId);
        _distributeIncomeAndPoints(gameId);

        delete orders[gameId][game.playerA.account];
        delete orders[gameId][game.playerB.account];
        delete commitments[gameId][game.playerA.account];
        delete commitments[gameId][game.playerB.account];
    }

    /// @notice Charges valid movement attempts and resolves destinations or combat.
    /// @dev Expects orders already normalized by _resolveAction or timeout defaults.
    ///      Combat requires two living fleets and a shared destination or position exchange.
    ///      Moving into a sector vacated toward a third sector does not cause combat.
    ///      Each Move pays one energy even if combat destroys the fleet or prevents arrival.
    /// @param gameId Identifier of the game whose movement orders are resolved.
    function _resolveMovementAndCombat(uint256 gameId) internal {
        Game storage game = games[gameId];
        CombatContext memory context;

        context.originA = game.fleetA.position;
        context.originB = game.fleetB.position;

        Order memory orderA = orders[gameId][game.playerA.account];
        Order memory orderB = orders[gameId][game.playerB.account];

        context.movingA = orderA.action == ActionType.Move;
        context.movingB = orderB.action == ActionType.Move;

        context.targetA = context.movingA
            ? orderA.destination
            : context.originA;

        context.targetB = context.movingB
            ? orderB.destination
            : context.originB;

        bool bothAlive = game.fleetA.ships > 0 && game.fleetB.ships > 0;
        bool sameDestination = context.targetA == context.targetB;
        context.swapping = context.targetA == context.originB && 
            context.targetB == context.originA && 
            context.movingA && 
            context.movingB;
        bool blocked = sameDestination || context.swapping;
        bool combat = blocked && bothAlive;

        // Remove energy
        if (context.movingA) game.playerA.energy -= 1;
        if (context.movingB) game.playerB.energy -= 1;

        if (!combat) {
            if (orderA.action == ActionType.Move) {
                game.fleetA.position = context.targetA;

                emit FleetMoved(
                    gameId,
                    game.playerA.account,
                    context.originA,
                    context.targetA
                );
            }

            if (orderB.action == ActionType.Move) {
                game.fleetB.position = context.targetB;

                emit FleetMoved(
                    gameId,
                    game.playerB.account,
                    context.originB,
                    context.targetB
                );
            }
        } else {
            _resolveCombat(gameId, context);
        }
    }

    /// @notice Applies simultaneous casualties and the final positions of both fleets.
    /// @dev Expects a context describing a collision between living fleets. Survivors occupy
    ///      their target except in an exchange, where they stay at their origin. Destroyed
    ///      fleets have zero ships and their base as a reference position. Emits CombatResolved,
    ///      FleetDestroyed for each destroyed fleet, and FleetMoved for relocated survivors.
    /// @param gameId Identifier of the game containing the combatants.
    /// @param context Original positions, proposed destinations and movement/exchange flags.
    function _resolveCombat(
        uint256 gameId,
        CombatContext memory context
    ) internal {
        Game storage game = games[gameId];
        Order memory orderA = orders[gameId][game.playerA.account];
        Order memory orderB = orders[gameId][game.playerB.account];

        (uint8 survivorsA, uint8 survivorsB) = _calculateCombat(
            game.fleetA.ships, 
            game.fleetB.ships, 
            orderA.action == ActionType.Defend, 
            orderB.action == ActionType.Defend
        );

        emit CombatResolved(
            gameId, 
            context.originA, 
            context.originB, 
            context.targetA, 
            context.targetB, 
            game.fleetA.ships - survivorsA, 
            game.fleetB.ships - survivorsB
        );

        game.fleetA.ships = survivorsA;
        game.fleetB.ships = survivorsB;

        if (survivorsA == 0) {
            game.fleetA.position = 0;
            emit FleetDestroyed(gameId, game.playerA.account);
        } else {
            uint8 finalA = context.swapping ? context.originA : context.targetA;
            game.fleetA.position = finalA;

            if (finalA != context.originA) {
                emit FleetMoved(
                    gameId,
                    game.playerA.account,
                    context.originA,
                    finalA
                );
            }
        }

        if (survivorsB == 0) {
            game.fleetB.position = uint8(maps[gameId].length) - 1;
            emit FleetDestroyed(gameId, game.playerB.account);
        } else {
            uint8 finalB = context.swapping ? context.originB : context.targetB;
            game.fleetB.position = finalB;

            if (finalB != context.originB) {
                emit FleetMoved(
                    gameId,
                    game.playerB.account,
                    context.originB,
                    finalB
                );
            }
        }
    }

    /// @notice Calculates survivors using each opponent's starting combat strength.
    /// @dev Strength equals ships plus one for Defend. Casualties are simultaneous and capped
    ///      at the fleet's ship count. Inputs are expected to respect the game cap of ten ships.
    /// @param shipsA Number of player A's ships before combat.
    /// @param shipsB Number of player B's ships before combat.
    /// @param defendingA Whether player A's effective order is Defend.
    /// @param defendingB Whether player B's effective order is Defend.
    /// @return survivorsA Number of player A's ships remaining after enemy damage.
    /// @return survivorsB Number of player B's ships remaining after enemy damage.
    function _calculateCombat(
        uint8 shipsA,
        uint8 shipsB,
        bool defendingA,
        bool defendingB
    ) internal pure returns (
        uint8 survivorsA,
        uint8 survivorsB
    ) {
        uint8 strengthA = shipsA + (defendingA ? 1 : 0);
        uint8 strengthB = shipsB + (defendingB ? 1 : 0);

        survivorsA = shipsA - _min(shipsA, strengthB);
        survivorsB = shipsB - _min(shipsB, strengthA);
    }

    /// @notice Returns the smaller of two ship-count values.
    /// @param a First value.
    /// @param b Second value.
    /// @return The minimum of a and b.
    function _min(uint8 a, uint8 b) internal pure returns(uint8) {
        if (a < b) return a;
        else return b;
    }

    /// @notice Transfers sectors to players whose Capture orders survived combat.
    /// @dev Expects validated Capture orders on capturable terrain. A fleet with zero ships
    ///      cannot capture. Merely winning a combat never transfers ownership. Emits SectorCaptured
    ///      with the previous and new owner; the new owner receives this round's territory income.
    /// @param gameId Identifier of the game whose captures are resolved.
    function _resolveCaptures(uint256 gameId) internal {
        Game storage game = games[gameId];

        uint8 originA = game.fleetA.position;
        uint8 originB = game.fleetB.position;

        Order memory orderA = orders[gameId][game.playerA.account];
        Order memory orderB = orders[gameId][game.playerB.account];

        if (orderA.action == ActionType.Capture && game.fleetA.ships > 0) {
            address prevOwner = sectorOwners[gameId][originA];
            sectorOwners[gameId][originA] = game.playerA.account;


            emit SectorCaptured(gameId, 
                                originA, 
                                prevOwner, 
                                game.playerA.account);
        }

        if (orderB.action == ActionType.Capture && game.fleetB.ships > 0) {
            address prevOwner = sectorOwners[gameId][originB];
            sectorOwners[gameId][originB] = game.playerB.account;

            emit SectorCaptured(gameId, 
                                originB, 
                                prevOwner, 
                                game.playerB.account);
        }
    }

    /// @notice Charges construction orders and adds one ship at each building fleet's base.
    /// @dev Expects validated Build orders with at least three energy and fewer than ten ships.
    ///      Runs after combat, so newly built ships do not fight this round. Zero-ship fleets
    ///      have already been normalized to their base and can be rebuilt. Emits ShipBuilt.
    /// @param gameId Identifier of the game whose construction orders are resolved.
    function _resolveBuilds(uint256 gameId) internal {
        Game storage game = games[gameId];
        Order memory orderA = orders[gameId][game.playerA.account];
        Order memory orderB = orders[gameId][game.playerB.account];

        SectorType positionA = maps[gameId][game.fleetA.position];
        SectorType positionB = maps[gameId][game.fleetB.position];

        if (orderA.action == ActionType.Build && positionA == SectorType.Base) {
            game.playerA.energy -= 3;
            game.fleetA.ships += 1;

            emit ShipBuilt(gameId, game.playerA.account, game.fleetA.ships);
        }

        if (orderB.action == ActionType.Build && positionB == SectorType.Base) {
            game.playerB.energy -= 3;
            game.fleetB.ships += 1;

            emit ShipBuilt(gameId, game.playerB.account, game.fleetB.ships);
        }
    }

    /// @notice Credits base income and the territories controlled after this round's captures.
    /// @dev Each player receives two base energy regardless of fleet position or survival.
    ///      Each station gives its owner one energy and one point; the core gives one energy
    ///      and three points. Applies on round ten too. Does not change territory ownership.
    /// @param gameId Identifier of the game receiving end-of-round income.
    function _distributeIncomeAndPoints(uint256 gameId) internal {
        Game storage game = games[gameId];

        game.playerA.energy += 2;
        game.playerB.energy += 2;

        for(uint8 i = 0; i < maps[gameId].length; i++) {
            address owner = sectorOwners[gameId][i];
            SectorType position = maps[gameId][i];

            Player storage player;

            if (owner == game.playerA.account) {
                player = game.playerA;
            } else if (owner == game.playerB.account) {
                player = game.playerB;
            } else {
                continue;
            }

            if (position == SectorType.EnergyStation) {
                player.points++;
                player.energy++;
            } else if (position == SectorType.CentralCore) {
                player.points += 3;
                player.energy++;
            }
        }
    }

    /// @notice Constructs the fixed five-by-five terrain map in memory.
    /// @dev Bases: 0 and 24. Stations: 2, 10, 14, 22. Core: 12. Obstacles: 6, 8, 16, 18.
    ///      All other positions retain the default Empty value. Does not initialize ownership.
    /// @return A terrain array of dimension squared elements.
    function initializeScenario() internal view returns(SectorType[] memory) {
        SectorType[] memory map = new SectorType[](dimension * dimension);

        // Las posiciones sin asignar son Empty, el valor 0 del enum.
        map[0] = SectorType.Base;
        map[24] = SectorType.Base;

        map[2] = SectorType.EnergyStation;
        map[10] = SectorType.EnergyStation;
        map[14] = SectorType.EnergyStation;
        map[22] = SectorType.EnergyStation;

        map[6] = SectorType.Obstacle;
        map[8] = SectorType.Obstacle;
        map[16] = SectorType.Obstacle;
        map[18] = SectorType.Obstacle;

        map[12] = SectorType.CentralCore;

        return map;
    }

    /// @notice Stores the winner after the final round's points have been distributed.
    /// @dev Compares total points, then currently controlled energy stations. The core does
    ///      not count toward the tiebreak. Equal points and station counts produce a draw.
    ///      Does not change status or emit final events; the caller performs those steps.
    /// @param gameId Identifier of the game whose final score is evaluated.
    function _checkResult(uint256 gameId) internal {
        Game storage game = games[gameId];

        if (game.playerA.points == game.playerB.points) {
            (uint32 playerAStations, uint32 playerBStations) = _getElectricStations(gameId);

            if (playerAStations > playerBStations) {
                game.result = GameResult.PlayerAWins;
            } else if (playerAStations < playerBStations) {
                game.result = GameResult.PlayerBWins;
            } else {
                game.result = GameResult.Draw;
            }
        } else if (game.playerA.points < game.playerB.points) {
            game.result = GameResult.PlayerBWins;
        } else {
            game.result = GameResult.PlayerAWins;
        }
    }

    /// @notice Counts the energy stations currently controlled by each player.
    /// @dev Ignores the core, bases, empty sectors, obstacles and unclaimed stations.
    /// @param gameId Identifier of the game whose territory is counted.
    /// @return playerAStations Number of energy stations controlled by player A.
    /// @return playerBStations Number of energy stations controlled by player B.
    function _getElectricStations(uint256 gameId) internal view returns(uint32 playerAStations, uint32 playerBStations) {
        Game memory game = games[gameId];

        for (uint8 i = 0; i < maps[gameId].length; i++) {
            SectorType sector = maps[gameId][i];

            if (sector != SectorType.EnergyStation) continue;

            address owner = sectorOwners[gameId][i];
            if (game.playerA.account == owner) {
                playerAStations++;
            } else if (game.playerB.account == owner) {
                playerBStations++;
            }
        }
    }

    /// @notice Normalizes a revealed order, returning Hold if it violates the action rules.
    /// @dev Relies on msg.sender being the participant represented by player, as in revealOrders.
    ///      Checks movement geometry, energy, fleet survival and the enemy-base restriction;
    ///      checks capture terrain/ownership; checks construction energy, base terrain and cap.
    ///      Defend requires a living fleet. Preserves destination even for Hold; only Move uses it.
    ///      No energy is charged and no game state is modified here.
    /// @param gameId Identifier of the game supplying terrain and ownership.
    /// @param player Snapshot of the revealing participant's account and resources.
    /// @param fleet Snapshot of that participant's fleet before round resolution.
    /// @param action Action to validate.
    /// @param destination Destination originally revealed by the participant.
    /// @return The requested legal order, or Hold carrying the same destination.
    function _resolveAction(
        uint256 gameId,
        Player memory player,
        Fleet memory fleet,
        ActionType action,
        uint8 destination
    ) internal view returns(Order memory) {
        Game memory game = games[gameId];

        Order memory order = Order({
            action: ActionType.Hold,
            destination: destination
        });

        if (action == ActionType.Move) {
            if(player.energy == 0) return order;
            if (!checkMove(fleet, maps[gameId], destination)) return order;

            uint256 enemyBase = msg.sender == game.playerA.account
                ? dimension * dimension - 1
                : 0;

            if (fleet.ships == 0) return order;
            if (destination == enemyBase) return order;
        } else if (action == ActionType.Capture) {
            SectorType sector = maps[gameId][fleet.position];

            if (fleet.ships == 0) return order;
            if (sector != SectorType.CentralCore && sector != SectorType.EnergyStation) return order;
            if (sectorOwners[gameId][fleet.position] == player.account) return order;
        } else if (action == ActionType.Build) {
            SectorType sector = maps[gameId][fleet.position];

            if (player.energy < 3) return order;
            if (sector != SectorType.Base) return order;
            if (fleet.ships >= 10) return order;
        } else if (action == ActionType.Defend) {
            if (fleet.ships == 0) return order;
        }

        return Order({
            action: action,
            destination: destination
        });
    }

    /// @notice Checks terrain, bounds and orthogonal adjacency for a proposed movement.
    /// @dev Does not check ships, energy, enemy bases or occupancy; those concerns belong to
    ///      action validation and simultaneous resolution. The current position is assumed valid.
    /// @param previousPosition Fleet snapshot containing the current position.
    /// @param map_ Initialized terrain array to query.
    /// @param newPosition Proposed zero-based sector index.
    /// @return True if the destination is in bounds, non-obstructed and exactly one orthogonal step away.
    function checkMove(Fleet memory previousPosition, 
                        SectorType[] memory map_,
                        uint256 newPosition) internal view returns(bool) {
        if (previousPosition.position == newPosition) return false;
        if (newPosition >= map_.length) return false;

        (uint256 prevRow, uint256 prevColumn) = getRowAndColumn(previousPosition.position, dimension);
        (uint256 newRow, uint256 newColumn) = getRowAndColumn(newPosition, dimension);

        if (map_[newPosition] == SectorType.Obstacle) return false;

        uint256 diffColumn = diff(newColumn, prevColumn);
        uint256 diffRow = diff(prevRow, newRow);

        if (diffColumn > 1 || diffRow > 1) return false;

        if (diffColumn + diffRow > 1) return false;

        return true;
    }

    /// @notice Converts a row-major sector index into row and column coordinates.
    /// @dev Coordinates are zero-based. The caller must supply a nonzero dimension; no board
    ///      bounds are checked here.
    /// @param position Linear sector index.
    /// @param dimension_ Number of columns in the square board.
    /// @return row Zero-based row of the position.
    /// @return column Zero-based column of the position.
    function getRowAndColumn(uint256 position, uint256 dimension_) internal pure returns(uint256 row, uint256 column) {
        row = position / dimension_;
        column = position % dimension_;
    }

    /// @notice Computes the absolute difference between two unsigned values.
    /// @param first First coordinate or value.
    /// @param second Second coordinate or value.
    /// @return Nonnegative distance between first and second.
    function diff(uint256 first, uint256 second) internal pure returns (uint256) {
        return first >= second ? first - second : second - first;
    }
}