# Dark Sector · Simulador TypeScript

Aplicación local completa para explorar las reglas del contrato `DarkSector.sol`. Incluye tablero, órdenes para ambos jugadores, rival automático, previsión de resultados, historial, guardado y repeticiones exportables.

## Abrir la aplicación

En macOS, abre la carpeta `simulator` y haz doble clic en **Iniciar.command**. Se abrirá una terminal y tu navegador. Mantén esa terminal abierta mientras juegas. Para detener la aplicación, pulsa Control + C en ella.

Si macOS no ejecuta ese archivo al abrirlo, usa la terminal de VS Code:

```bash
cd /Users/juliorl8/Documents/Blockchain/dark-sector/simulator
npm ci
npm run dev
```

Abre la dirección que muestra la terminal (normalmente `http://127.0.0.1:5173`). `npm ci` solo hace falta la primera vez o cuando cambie `package-lock.json`.

Requisito: Node.js 24.12 o posterior, con npm. Para la comparación con Solidity también necesitas Foundry (`forge` y `anvil`).

## Primera partida

1. Selecciona **Helios** o **A · Helios**.
2. Pulsa **Mover**. Se iluminan los destinos válidos; el primero queda seleccionado automáticamente. Puedes elegir otro en el tablero.
3. Selecciona Umbra y prepara su orden, o activa **Rival automático**.
4. Pulsa **Resolver ronda**. Ambas acciones se resuelven juntas.
5. Consulta el registro inferior para ver movimientos, bajas, capturas e ingresos.
6. Usa las flechas o la barra del historial para volver a estados anteriores. **Presente** vuelve a la partida actual. No puedes modificar rondas pasadas.

Para una demostración rápida, pulsa **Demo automática**. Resuelve el resto de la partida usando una heurística para ambos jugadores. **Detener demo** pausa el avance.

## Escenarios

- **Nueva expedición:** partida normal desde las bases.
- **Contacto hostil:** tres naves frente a una para explorar ataques.
- **Última defensa:** tres contra dos; defender modifica las bajas.
- **Volver a empezar:** flotas destruidas; prueba construir para reconstruirlas.
- **La última ronda:** captura y comprueba el marcador final.

Los escenarios especiales son situaciones de laboratorio; no todos parten de una partida jugada desde cero. Cambiar de escenario reinicia la partida, con confirmación si ya tiene historial.

## Qué hace y qué no hace

La pantalla es un **laboratorio de resolución local**. No conecta una wallet, no custodia fondos y no envía transacciones. Puedes controlar ambos bandos y ver la previsión con sus órdenes actuales. No ofrece secretos entre dos jugadores ni multijugador remoto.

El rival automático es una heurística sencilla para demostrar el juego; no garantiza decisiones óptimas.

El protocolo real de commit–reveal se ejecuta en la prueba diferencial contra una instancia temporal de Anvil. La pantalla se centra en las acciones y sus resultados, sin obligarte a gestionar hashes. El motor incluye la resolución de ausencias en Reveal y sus faltas; la interfaz visual no simula un reloj ni la fase de compromiso.

La partida se guarda en `localStorage` del navegador. Las órdenes en preparación no se guardan: solo las rondas resueltas. Los puertos o navegadores distintos tienen guardados distintos. **Exportar** descarga una repetición JSON. **Importar** valida el formato y recalcula todos los estados; no confía en estados arbitrarios del archivo.

## Las reglas implementadas

- Diez rondas y una flota por jugador, con hasta diez naves.
- Movimiento ortogonal por una energía; no se permiten obstáculos ni la base rival.
- Colisiones e intercambios generan combate. Cada bando inflige daño con su fuerza inicial; defender suma uno.
- Un superviviente de intercambio queda en su origen. Los demás supervivientes ocupan el destino del combate. Las flotas destruidas quedan con cero naves y posición de referencia en su base.
- Capturar exige sobrevivir y dedicar la acción a la captura. El control persiste al abandonar el sector.
- Construir cuesta tres, exige estar en la base y añade una nave al final de las acciones.
- Cada base paga dos de energía; las estaciones pagan una energía y un punto; el núcleo, una energía y tres puntos. La captura produce desde esa ronda.
- La décima ronda también genera ingresos y puntos. Gana el mayor marcador; el desempate cuenta solo estaciones energéticas, no el núcleo.
- Dos faltas de revelación provocan derrota sin ejecutar ni pagar esa ronda. Si ambos llegan a dos, hay empate.

## Comprobar el proyecto

Desde `simulator`:

```bash
npm test
npm run build
npm run test:differential
```

- `npm test`: pruebas del motor, las repeticiones y la heurística. Incluye 400 combinaciones de combate y 100 partidas generadas (1.000 rondas).
- `npm run build`: comprueba los tipos y genera la aplicación en `dist/`.
- `npm run test:differential`: copia el contrato actual a una carpeta temporal, compila un contrato de pruebas con optimización y levanta su propio Anvil en un puerto local libre. Compara 140 estados: escenarios controlados, casos generados, cuatro partidas completas y vencimientos. Usa el commit–reveal real y alterna el orden de revelación. Al terminar detiene Anvil y elimina los archivos temporales.

La prueba diferencial no cambia tu contrato, no requiere claves privadas ni un nodo externo y genera `reports/differential.json`. Si falla, muestra el escenario reproducible. Compila de nuevo el Solidity actual en cada ejecución para no contrastar contra una versión antigua.

Si has movido el simulador fuera del repositorio:

```bash
npm run test:differential -- --repo /ruta/al/repositorio/dark-sector
```

Los estados generados usan un contrato auxiliar de pruebas para preparar energía, naves y propietarios. Las órdenes siempre se ejecutan por las funciones públicas de commit–reveal. Es una comprobación de consistencia, no una auditoría ni una prueba exhaustiva de todos los estados posibles.

## Organización para aprender

```text
src/
  engine/
    game.ts       Tipos, validación y resolución pura de rondas
    replay.ts     Escenarios y validación de repeticiones
    bot.ts        Heurística de demostración
  main.ts         Tablero, controles e historial
  style.css       Diseño adaptable a pantallas pequeñas
scripts/
  differential.ts Comparación del motor con Solidity en Anvil
tests/
  engine.test.ts  Pruebas independientes del navegador
```

Empieza leyendo `createGame`, `invalidReason` y `resolveRound` en `game.ts`. El motor no depende del navegador ni de viem. `main.ts` lo utiliza para dibujar el resultado y `differential.ts` para compararlo con Solidity.

## Construcción y publicación

`npm run build` crea una aplicación estática en `dist/`. Puedes previsualizarla con `npm run preview`. No se ha publicado en Internet ni se ha añadido conexión con una red real.

Las fuentes de Google son opcionales; si no hay conexión se usa la fuente del sistema. No hay imágenes o servicios necesarios para resolver las partidas.

Referencias: [Vite](https://vite.dev/guide/), [clientes de prueba de viem](https://viem.sh/docs/clients/test).
