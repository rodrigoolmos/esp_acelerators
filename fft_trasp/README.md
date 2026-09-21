# Transposición con interfaz DMA ESP

`transpose_rtl_basic_dma64.sv` adapta `transpose.sv` y `bram.sv` a los
mismos puertos de configuración, estado y DMA de 64 bits que
`exmple/test_rtl_basic_dma64.sv`.

La matriz de entrada se almacena por filas. La salida contiene la matriz
transpuesta, también por filas: `B[col][row] = A[row][col]`.
Cada elemento es una muestra compleja de 64 bits: I de 32 bits y Q de
32 bits. La muestra se mueve completa, sin separar componentes, cambiar
su representación ni conjugarla. `transpose.sv` usa 64 bits por defecto.

## Configuración

| Señal/parámetro | Significado |
| --- | --- |
| `NUM_ROWS`, `NUM_COLS` | Dimensiones de entrada, por defecto 8 y 16. Parámetros de síntesis, potencias de dos >= 2. |
| `conf_info_reg0` | Dirección base de entrada y salida, en transferencias DMA de 64 bits, siguiendo la convención del ejemplo. |
| `conf_info_reg1` | Longitud: debe ser exactamente `NUM_ROWS * NUM_COLS` (128 por defecto). |
| `conf_done` | Pulso de un ciclo para iniciar desde reposo. La configuración se registra al aceptarlo. |
| `acc_done` | Pulso de un ciclo tras aceptar DMA el último dato de salida, o al rechazar una configuración. |
| `debug[31]` | Longitud incorrecta. Se mantiene hasta la siguiente configuración o reset. |
| `debug[2:0]` | Estado: IDLE=0, DMA_READ=1, DMA_WRITE=3, DONE=4. |

El resultado sobrescribe la misma región de entrada. Primero se carga toda
la matriz en BRAM; después se inicia la escritura DMA. Una longitud inválida
termina con `acc_done` y `debug[31]=1`, sin iniciar transacciones DMA.
`conf_done` solo se atiende en reposo; esperar a que termine el pulso
`acc_done` antes de iniciar otra operación.

Cada transferencia contiene una muestra compleja. El TB usa esta convención:

```text
data[31:0]  = I[i]
data[63:32] = Q[i]
```

El RTL conserva los 64 bits en sus posiciones originales; también preserva
un formato externo con las mitades I/Q invertidas. Una matriz 8×16 ocupa
128 transferencias de 64 bits (1024 bytes).

La FSM sigue `IDLE → DMA_READ → DMA_WRITE → DONE`: la transposición se
realiza al escribir la BRAM y no necesita una fase COMPUTE. Los indicadores
`read_started` y `write_started` separan la aceptación del descriptor de
la transferencia de datos dentro de cada estado DMA.

El adaptador respeta `valid/ready` y acepta una muestra por ciclo en lectura
si DMA la proporciona. En salida, `output_valid` introduce un ciclo para
la lectura síncrona de BRAM antes de enviar cada muestra (dos ciclos por
muestra sin bloqueos). Mientras DMA bloquea, la dirección y el dato se
mantienen estables.

`rst_n` reinicia el control del adaptador; no borra la BRAM. Cada operación
válida carga de nuevo todos los elementos antes de leer la salida.

## Testbench

`tb_transpose_acc_esp.sv` usa la interfaz y el agente de memoria de
`agent_transpose_esp.sv`, adaptados del ejemplo. Los estímulos cambian en el
flanco de bajada para evitar carreras con el RTL.

Comprueba cuatro transposiciones, distintos patrones y direcciones base,
operaciones consecutivas sin reset, pausas de lectura, bloqueos de escritura,
estabilidad de los descriptores y datos bloqueados, número de transferencias,
pulso `acc_done`, tres longitudes inválidas (incluida la antigua longitud
de 64 transferencias) y recuperación posterior. Los patrones tienen valores
distintos en I y Q para detectar truncamientos o intercambio de componentes.

Desde este directorio, con Vivado en `PATH`:

```bash
xvlog -sv -i . bram.sv transpose.sv transpose_rtl_basic_dma64.sv tb_transpose_acc_esp.sv
xelab tb_transpose_acc_esp -s tb_transpose_dma_sim --timescale 1ns/1ps
xsim tb_transpose_dma_sim -runall
```

El TB incluye el agente: no añadirlo por separado ni compilar los archivos
de `exmple/` en esta simulación, pues declaran otra interfaz con el mismo nombre.
Para síntesis, añadir solamente `bram.sv`, `transpose.sv` y
`transpose_rtl_basic_dma64.sv`; seleccionar este último como módulo superior.

Resultado comprobado con Vivado XSim 2023.2:

```text
PASS DMA: 4 matrices, 512 muestras I/Q verificadas, pausas y 3 configuraciones invalidas
```

Esta integración cubre el módulo RTL con la interfaz del ejemplo y su
simulación. No incluye el registro del acelerador en un sistema ESP completo
ni su controlador de software.
