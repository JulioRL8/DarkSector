// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

enum GameStatus {
    WaitingForPlayer,
    Active,
    Finished
}

enum SectorType {
    Empty,
    Obstacle,
    EnergyStation,
    Base,
    CentralCore
}

enum GameResult {
    Pending,
    PlayerAWins,
    PlayerBWins,
    Draw
}

struct Player {
    address account;
    uint32 energy;
    uint32 points;
}

struct Fleet {
    uint8 position;
    uint8 ships;
}

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

enum ActionType {
    Hold,
    Move, 
    Capture,
    Defend,
    Build
}

struct Order {
    ActionType action;
    uint8 destination;
}

enum RoundPhase {
    Commit,
    Reveal
}

struct OrderCommitment {
    bytes32 commitment;
    bool committed;
    bool revealed;
}

struct CombatContext {
    uint8 originA;
    uint8 originB;
    uint8 targetA;
    uint8 targetB;
    bool movingA;
    bool movingB;
    bool swapping;
}

contract DarkSector {
    uint dimension = 5;
    uint256 currentGameId = 0;
    uint256 constant maxRound = 10;

    mapping(uint256 => Game) games;
    mapping(uint256 => SectorType[]) maps;

    mapping(uint256 => mapping(uint8 => address)) 
        internal sectorOwners;
    mapping(uint256 => mapping(address => Order)) 
        internal orders;
    mapping(uint256 => mapping(address => OrderCommitment))
        internal commitments;

    mapping(uint256 => mapping(address => uint8))
        public revealFaults;

    uint256 constant revealTime = 5 minutes;

    // Errors
    error InvalidAddress();
    error InvalidStatus();
    error Forbidden();
    error AlreadyReady();
    error GameDoesNotExists();
    error IncorrectMove();
    error DeadlineReached();
    error HashNotValid();
    error DeadlineNotReached();

    // Events 
    event GameCreated(uint256 indexed gameId, address indexed creator);
    event GameStarted(
        uint256 indexed gameId,
        address indexed playerA,
        address indexed playerB
    );
    event PlayerReady(uint256 indexed gameId, address indexed player);
    event RoundResolved(uint256 indexed gameId, uint8 round);
    event GameFinished(uint256 indexed gameId); 
    event FleetMoved(
        uint256 gameId, 
        address indexed user, 
        uint256 origin, 
        uint256 destination
    );
    event SectorCaptured(
        uint256 gameId,
        uint8 position,
        address indexed previousOwner,
        address indexed newOwner
    );
    event GameResultDeclared(
        uint256 indexed gameId,
        GameResult result,
        uint32 pointsA,
        uint32 pointsB
    );
    event CombatResolved(
        uint256 indexed gameId,
        uint8 originA,
        uint8 originB,
        uint8 targetA,
        uint8 targetB,
        uint8 lossesA,
        uint8 lossesB
    );
    event FleetDestroyed(
        uint256 indexed gameId,
        address indexed player
    );
    event ShipBuilt(
        uint256 indexed gameId,
        address indexed player,
        uint8 totalShips
    );

    constructor() { }

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

    function getGame(uint256 gameId) external view
        returns (Game memory) {
        require(gameId < currentGameId, GameDoesNotExists());
        
        return games[gameId];
    }

    function getSectorType(uint8 position, uint256 gameId) external view
        returns (SectorType) {
        require(gameId < currentGameId, GameDoesNotExists());
        
        return maps[gameId][position];
    }

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

    function getSectorOwner(
        uint256 gameId,
        uint8 position
    ) external view returns (address) {
        require(gameId < currentGameId, GameDoesNotExists());
        require(position < maps[gameId].length);
        return sectorOwners[gameId][position];
    }

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

    function _min(uint8 a, uint8 b) internal pure returns(uint8) {
        if (a < b) return a;
        else return b;
    }

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

    function getRowAndColumn(uint256 position, uint256 dimension_) internal pure returns(uint256 row, uint256 column) {
        row = position / dimension_;
        column = position % dimension_;
    }

    function diff(uint256 first, uint256 second) internal pure returns (uint256) {
        return first >= second ? first - second : second - first;
    }
}