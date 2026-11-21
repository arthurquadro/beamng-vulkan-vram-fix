# BeamNG.drive Vulkan VRAM Leak Fix (`vulkanVramFix`)

> 🇺🇸 **English version:** [README.md](README.md)

Um mod leve e não-destrutivo (`v1.1.0`) para **BeamNG.drive** que impede o **estouro progressivo de VRAM no Vulkan** — quando a VRAM sobe continuamente (de ~100 em ~100 MB) com **qualquer veículo** até lotar a placa, derrubar o FPS ou travar com `VK_ERROR_DEVICE_LOST` (e só cai de volta quando você muda alguma opção gráfica).

- **Funciona com qualquer veículo e qualquer mapa** — não altera nenhum arquivo de veículo nem do jogo.
- **Funciona em placas AMD, NVIDIA e Intel** (atua apenas no Vulkan; fica inativo automaticamente no DirectX 11 / DirectX 12).
- **100% Lua puro (apenas 2 arquivos pequenos)** — zero conflito com outros mods e carregamento idempotente.
- **Preserva todas as suas configurações gráficas** — você pode mudar gráficos, resolução, Profundidade de Campo (DoF) e espelhos livremente no menu sem quebrar a correção.

---

## Por que Esse Problema Acontece (Causa Raiz)

A análise técnica do executável `BeamNG.drive.x64.exe` (`v0.40.6.0`) revelou por que a VRAM sobe continuamente no Vulkan (enquanto no DirectX 12 fica estável) e por que mudar qualquer opção gráfica fazia a VRAM cair na hora:

1. **Pools internos do Vulkan não são limpos durante a gameplay:** o método `GFXVkDevice::endScene` nunca apara a lista de slabs de transferência de `16 MB` (`"Buffer volatile cpu"`) e retém até `32 × 8 MB` de slabs dinâmicos por bucket na VRAM, além de outros caches internos. Quando você muda uma opção gráfica, o jogo chama `GFXVkWindowTarget::resetModeInternal` → `GFXVkDevice::waitIdle()`, limpando tudo de uma vez.
2. **Coletor automático de VRAM órfão:** o próprio motor do BeamNG já possui uma função de limpeza sob pressão de VRAM (`GFXVkDevice::vtable[+0x108]` em `0x140F10260` → `checkVmaHeapBudgets(0.85f)` em `0x140F0ED80` → `waitIdle()` em `0x140F1A710`) que dispara quando o uso VMA `DEVICE_LOCAL` passa de 85% de `budgetBytes` (ou memória não-local passa de 1 GB, ou após 5 chamadas). Porém, o **único chamador** dela no binário é `GuiCanvas::repaintUIThrottled()`, que o Lua original só chama durante a **tela de carregamento** (`updateLoadingProgress`), nunca durante a gameplay normal.
3. **Orçamento padrão exagerado do `transientPool`:** a variável interna `$gfx::transientPoolBudgetMB` vem em **`1536 MB`** (1,5 GB), segurando render targets ociosos — algo especialmente pesado em placas de 8 GB sem Resizable BAR (BAR de 256 MB).

---

## Novidades da `v1.1.0` (Alinhamento com o Orçamento VMA)

O disassembly de `GFXVkDevice::getMemoryInfo` (`0x140EFBA40`, `vtable[+0x80]`) e `Engine.Render.getMemoryInfo` (`0x14066BA20`) revelou um detalhe importante sobre como o BeamNG reporta a VRAM:

- O campo `availableBytes` é calculado em C++ como `max(0, budgetBytes - usageBytes)` — **e não** `dedicatedBytes - usageBytes` (`7.368 MB` de orçamento VMA contra `8.192 MB` físicos em uma RX 580 8 GB).
- Medir sobre `dedicatedBytes` superestimava o uso VMA real em `~824 MB`. Por isso, disparar em `78%` de `dedicatedBytes` pegava o VMA em `~75,7%` de `budgetBytes`, fazendo `checkVmaHeapBudgets(0.85f)` rejeitar os pulsos 1–4 em 12 de 16 limpezas num teste de 37 minutos (`~485–650 ms` em 5 pulsos).
- **A `v1.1.0` lê `usageBytes` e `budgetBytes` diretamente** e dispara a limpeza em **`≥ 85,2%` do orçamento VMA** (ainda deixando **~1,87 GiB / 1,9 GB** de VRAM física livres em placas de 8 GB):
  - **Limpeza garantida no 1º pulso (`~198 ms`)** em qualquer GPU AMD, NVIDIA ou Intel.
  - **Intervalo ~35% maior entre limpezas** (`+700 MB` de folga extra absorvida antes de limpar).
  - **Carregamento idempotente no `modScript.lua`** via `extensions.isExtensionLoaded("vulkanVramFix")` evitando carga duplicada.

---

## O que Este Mod Faz

1. **Reduz `$gfx::transientPoolBudgetMB` de `1536 MB` para `384 MB`** no Vulkan (reaplicado automaticamente ao iniciar mapa ou alterar gráficos, sem mexer em nenhuma opção visual do jogador).
2. **Reativa o coletor de memória Vulkan do próprio jogo durante a gameplay:** monitora `Engine.Render.getMemoryInfo()` uma vez por segundo (custo de CPU praticamente nulo):
   - **Em gameplay ativo:** ao atingir **≥ 85,2% de `budgetBytes` no VMA** (ou ao atingir o piso físico de 1,45 GiB livres com ≥ 85% do orçamento VMA), chama `Canvas:repaintUIThrottled()` com segurança fora do passe de renderização (`onUpdate`), esvaziando os pools acumulados **no primeiro pulso (~198 ms)** antes que a VRAM lote.
   - **Em pausa:** faz limpeza oportunista a partir de **≥ 72% do orçamento VMA** enquanto o menu de pausa está aberto.
   - **Proteção anti-loop:** se uma limpeza recuperar menos de `192 MB` (indicando que a VRAM está legitimamente ocupada por texturas estáticas da cena), aumenta automaticamente o intervalo de espera (`25 s → 60 s`).

### Telemetria Comprovada (`beamng.2.log` — Teste de Estresse de 37 Minutos, Citybus + 7 Veículos de Tráfego/Polícia, RX 580 8 GB Vulkan)

- **16 limpezas automáticas concluídas sem falhas** durante 37 minutos contínuos de jogo, recuperando **1.972–2.147 MB por limpeza** e trazendo o uso real do VMA de volta para `~3.525 MB` (`4.349–4.380 MB` na escala relativa física).
- **Tempo de limpeza em 1 pulso:** `~198 ms` (ex.: `Trigger` → `reclaimed 2051–2056 MB`).
- **Erros evitados:** **0** erros `Failed to wait for fences` e **0** avisos `bindless: material cbv array exhausted (8192 slots)` durante os 37 minutos protegidos (enquanto sessões sem o mod registraram ambos).

---

## Como Instalar

### Opção 1 — Instalação Fácil (Recomendada)
1. Baixe o arquivo `beamng_vulkan_vram_fix.zip` na aba [**Releases**](https://github.com/arthurquadro/beamng-vulkan-vram-fix/releases/latest).
2. Coloque o `.zip` (sem extrair) na pasta de mods do BeamNG:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
   *(Normalmente `C:\Users\<SeuUsuario>\AppData\Local\BeamNG\BeamNG.drive\current\mods\`.)*
3. Certifique-se de que o mod esteja **Ativo** no Gerenciador de Mods do jogo (ou veja a Opção 3 abaixo caso use "Desativar Todos os Mods").
4. Abra o **BeamNG.drive** no modo **Vulkan**.

### Opção 2 — Instalação Descompactada (Código-Fonte)
1. Baixe ou clone este repositório.
2. Copie as pastas `scripts/` e `lua/` para:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beamng_vulkan_vram_fix\
   ```
3. Abra o **BeamNG.drive** no modo **Vulkan**.

### Opção 3 — Instalação Persistente à Prova de Desativação (Opcional)
Como `core_modmanager.initDB()` varre `/scripts/*/modScript.lua` direto na raiz da pasta de usuário mesmo se todos os mods estiverem desativados:
1. Extraia `lua/ge/extensions/vulkanVramFix.lua` e `scripts/beamng_vulkan_vram_fix/modScript.lua` diretamente em:
   ```text
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\
   ```
2. Assim a proteção continua ativa mesmo se você clicar em **"Desativar Todos os Mods"** (sem alterar nenhum arquivo original da Steam).

---

## Comandos no Console do Jogo (Opcional)

Abra o console (`~` ou `'`), selecione o modo **BeamNG - Lua / GE** e use:

| Comando | Função |
| :--- | :--- |
| `vulkanVramFix.status()` | Mostra versão, % do orçamento VMA, VRAM física, `$gfx::transientPoolBudgetMB`, total de limpezas e MB recuperados. |
| `vulkanVramFix.flushNow()` | Executa uma limpeza imediata dos pools Vulkan na hora. |
| `vulkanVramFix.setBudgetMB(512)` | Ajusta o `$gfx::transientPoolBudgetMB` (`128`–`2048` MB). Útil em placas com 12 GB+ de VRAM. |
| `vulkanVramFix.setAutoFlush(false)` | Desativa temporariamente a limpeza automática (`true` para reativar). |

---

## Opcional: Parâmetros de Inicialização na Steam (Windows)

Várias camadas implícitas de terceiros no Vulkan (OBS, Steam Overlay, Steam Fossilize, Epic Online Services, RTSS, AMD Switchable Graphics) podem empilhar sobre o driver e piorar a estabilidade. Você pode desativá-las apenas para o BeamNG em **Steam → BeamNG.drive → Propriedades → Opções de Inicialização** (sem espaço antes de `&`):

```cmd
cmd /c "set DISABLE_VULKAN_OBS_CAPTURE=1& set EOS_OVERLAY_DISABLE_VULKAN_WIN64=1& set DISABLE_VK_LAYER_VALVE_steam_overlay_1=1& set DISABLE_VK_LAYER_VALVE_steam_fossilize_1=1& set DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1& set DISABLE_RTSS_LAYER=1& %command% -gfx vk"
```

- Remova `set DISABLE_RTSS_LAYER=1&` se quiser manter o overlay do MSI Afterburner / RivaTuner visível na tela.
- `DISABLE_LAYER_AMD_SWITCHABLE_GRAPHICS_1=1` só tem efeito em placas AMD e é ignorado com segurança em NVIDIA/Intel.

---

## Observações e Limitações Conhecidas

- Quando o uso VMA atinge o limite de 85,2% em gameplay, a chamada a `Canvas:repaintUIThrottled()` pode causar uma piscada bem rápida (~1 frame) no instante da limpeza.
- Testado no **BeamNG.drive v0.40.6.0**. Atualizações futuras do jogo podem corrigir a limpeza dos pools Vulkan nativamente na engine.

---

## Licença

Licenciado sob a **MIT License** — veja [LICENSE](LICENSE).
