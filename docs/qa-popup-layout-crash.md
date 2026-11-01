# Preview 20: crash de layout ao alternar Saída/Entrada

Status: falha física relatada pelo usuário; não corrigida nem reproduzida automaticamente até este checkpoint.

O usuário confirmou que a exceção ocorreu depois de várias alternâncias Saída/Entrada. O texto anexado registra NSGenericException por excesso de Layout Window passes, com NSScrollView, SwiftUI, NSThemeFrame, NSWindow e commit de Core Animation no stack. O novo caminho de resize do Preview 20 usa window.animator().setFrame; a causa precisa ser distinguida por reprodução.

A cópia do Preview 20 permanece como evidência, não como candidato aprovado. O CI d5c0d1f passou 1039 testes, 28 native TSan e 93 testes DSP em cada sanitizer e seu pacote foi verificado, mas isso NÃO valida esse comportamento físico.

## Ensaios locais sem sobrepor a tela

- Fixture mínima com ScrollView e RootViewModifier, compilada com -O: 12 trocas, sem exceção.
- MenuBarPopupView real em host inerte, sem iniciar captura nem monitores: 24 trocas, tamanho compacto, passou.
- Mesmo popup no tamanho Large do Preview 20: 24 trocas, passou.
- App e teste com -O, ligados a host inerte sem executar FineTuneApp.main: 24 trocas, passou. Evidência em work/popup-hosting-optimized-baseline.log e argumentos de ligação em work/popup-layout-crash-repro/.
- Teste adicional sem override do setter de frame: 24 trocas, passou.
- Tamanho compacto restaurado: 120 trocas por cenário, 3 e 12 saídas fictícias, 2 entradas, 3 apps, incluindo lista que requer rolagem e reversões antes de terminar a animação. 4 métodos de teste (2 suites) passaram; 240 trocas no stress. Log work/popup-hosting-rapid-stress.log, run 20261102-062343-201769.
- Ensaio de mouseDown sintético fora da tela não selecionou o segmento. Falhou asserções de seleção; não é reprodução do crash e foi removido do teste final. Log work/popup-hosting-tracking-baseline.log preserva essa distinção.

As janelas dos testes ficam 10 mil pontos fora de todos os monitores, não ativam nem recebem mouse. A propriedade de segurança é verificada antes e depois de orderBack. A variação de renderização entre janela fora da tela e popup real continua sendo uma limitação relevante. Esses passes são smoke coverage, não um teste de regressão que já capturou a exceção.

## Mudanças locais e próximo dado necessário

O seletor foi restaurado para controlSize Regular e SF Symbols Medium, a preferência anterior do usuário. A classe Regular é coerente com a instância Regular / Over-glass inspecionada no UI Kit (24 pt nessa instância), mas a medida não foi imposta como constante universal. A cápsula, papel tabs e material continuam nativos; não foi adicionada decoração.

Um patch de diagnóstico foi preparado em work/popup-layout-diagnostics.patch. O usuário pediu em seguida para adiar o diagnóstico e focar no visual; o patch não foi aplicado: opt-in por ambiente, somente geometria/model frame, pedidos/retornos de frame e trocas de direção, limite de 20000 linhas, arquivo local com permissão 0600. Sem screenshot, áudio, títulos/nomes de aplicativos, perfil ou captura de teclado. A proposta mantém o algoritmo de resize para observar a falha original; não tenta engolir a exceção. Nenhum preview novo foi aberto automaticamente.

Referências primárias: docs/qa-popup-layout-primary-research.md. Skills instaladas e suas origens/hashes: outputs/FineTune-skills-instaladas.json (no workspace pai).

## Direcionamento final desta etapa

Por pedido explícito do usuário, o diagnóstico do crash está adiado. Somente o tamanho compacto será entregue no Preview 21, sem ativar instrumentação e sem alegar correção da exceção. Release/merge continuam fora do escopo.
