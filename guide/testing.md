# Testes do FineTune

Execute a suíte unitária completa a partir do repositório:

```sh
python3 scripts/run-tests.py
```

O script usa Xcode completo (não apenas Command Line Tools), respeita `DEVELOPER_DIR` quando definido e não altera o `xcode-select` do sistema. Compila app e alvos de teste em Debug; executa todos os testes habilitados de `FineTuneTests`, tanto Swift Testing quanto XCTest, incluindo os benchmarks de DSP.

Cada execução salva `build.log`, `unit.log`, `unit.xcresult` e `unit-summary.json` em `build/tests/runs/<data-hora>/`. Falhas de compilação/teste, filtros sem testes e execuções inteiramente ignoradas retornam erro. Os casos parametrizados aparecem detalhados no `.xcresult`; a contagem do resumo não é a soma de todas as variações.

## Isolamento

O modo unitário carrega `FineTune.debug.dylib` em uma cópia do runner `xctest`, dentro de um app hospedeiro vazio com assinatura ad-hoc. Não executa `FineTuneApp.init()`: portanto não inicia captura, limpeza de dispositivos órfãos nem solicita permissões de produção. O hospedeiro continua oferecendo o contexto AppKit necessário para janelas e notificações.

Alguns testes consultam propriedades/saúde do Core Audio e outros criam janelas AppKit. Isso não equivale a um teste físico de áudio em HDMI, Bluetooth ou durante repouso. Os benchmarks usam buffers sintéticos e não medem a carga do app em uso real.

## Execuções direcionadas

```sh
python3 scripts/run-tests.py --only FineTuneTests/HUDInteractionTests
python3 scripts/run-tests.py --only FineTuneTests/AudioProcessMonitorTests
```

Repita `--only` para escolher várias suítes. `--skip-build` reutiliza a última compilação: use apenas quando o código não mudou. `--build-dir /caminho/temporario` muda a pasta de compilação/resultados; `--packages-dir /caminho/cache` reutiliza checkouts das dependências.

## Integração de interface

```sh
python3 scripts/run-tests.py --suite ui
python3 scripts/run-tests.py --suite all
```

Esses modos incluem `FineTuneUITests`, que inicia o app real com `--ui-testing`. O host de UI atual ainda inicializa os serviços de áudio; use uma sessão dedicada e feche o FineTune em uso antes. O script recusa essa execução enquanto outro processo FineTune estiver aberto. Podem ser necessárias permissões de Acessibilidade/Automação; alguns testes dependem de dispositivos disponíveis. `--suite all` executa unitários e integração, não somente os unitários.

## O que foi reforçado no HUD

Os testes anteriores de posição e contagem de `show()` não detectavam roubo de foco. `HUDInteractionTests` agora verifica painéis reais: preservação da janela key, impossibilidade de o HUD virar key/main, cliques externos devolvidos intactos, cliques internos preservados, fechamento imediato, temporizador real, permanência durante hover e rejeição de um fade antigo após reapresentação.

A suíte utiliza geometria e detecção de fullscreen controladas, sem depender da janela que o desenvolvedor está usando. O comportamento visual e o arraste sobre aplicativos de terceiros devem também ser conferidos na build instalada.

## Armazenamento e serviços externos

O runner unitário define `FINETUNE_TEST_MODE=unit` e um `FINETUNE_TEST_DATA_ROOT`
exclusivo para cada execução, antes de carregar a biblioteca do app. Configurações,
perfis/cache AutoEQ e diagnósticos usam `runs/<execução>/unit-data/`. O override de
crossfade usa um domínio UserDefaults próprio da execução. O domínio da instalação
normal não é alterado. Não defina essas variáveis na instalação de uso diário.

No host unitário, o serviço de login padrão funciona em memória e o catálogo AutoEQ
não inicia busca em rede em background. Os testes do binding injetam um serviço que
registra as chamadas: verificam a integração sem registrar login no macOS. Fora do
modo unitário, os diretórios, o carregamento do catálogo e ServiceManagement mantêm
o comportamento de produção.

Use `scripts/run-tests.py` para unitários. Cmd+U e `xcodebuild test` com o esquema
normal continuam sujeitos ao host de aplicação desse esquema. Os modos `ui` e `all`
continuam exigindo sessão dedicada: a inicialização real de áudio e as permissões
desses hosts ainda não foram isoladas.

## Integração contínua

`.github/workflows/ci.yml` compila Debug e executa todos os unitários pelo runner;
em seguida compila Release sem assinatura de distribuição. Os resultados, o storage
unitário e os logs são preservados como artefatos inclusive em falhas. O runner usa
macOS 26 e o Xcode estável disponível nessa imagem, registrando as versões no log.
A execução remota só será confirmada após envio ao GitHub; este arquivo não publica
releases. A compilação não substitui homologação física em macOS 14.2 ou outros
sistemas suportados.
