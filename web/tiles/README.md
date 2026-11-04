# Atlas de tiles (opcional)

O `mz_navigation` nao distribui o conjunto completo de tiles. O mapa padrao usa
o atlas estatico otimizado em `web/assets/los-santos-atlas.webp`, sem CDN, com
proveniencia e hash registrados em `web/assets/atlas.json`.

Para usar um atlas cartografico real, o dono do servidor precisa:

1. possuir licenca de redistribuicao dos tiles;
2. publicar os arquivos em `mz_navigation/web/tiles/`;
3. criar `mz_navigation/web/tiles/atlas.json` com metadados;
4. habilitar `Config.Map.tiles.enabled = true` em `config.lua`.

## Formato

```
web/tiles/
  atlas.json
  0/0/0.jpg
  1/0/0.jpg ... 1/1/1.jpg
  ...
  5/0/0.jpg ... 5/31/31.jpg
```

- tiles `256x256`;
- zoom `0..5`, grade `2^zoom` por eixo;
- formato compativel com o atlas legado observado em `ref/races/ui/mapStyles/styleAtlas`.

## atlas.json

```json
{
  "schemaVersion": 1,
  "license": "Nome da licenca e URL do termo",
  "attribution": "Credito obrigatorio exibido no mapa",
  "source": "Origem do atlas",
  "generatedAt": "2026-01-01"
}
```

Sem `web/tiles/atlas.json`, o servidor anuncia `tiles.enabled = false` e a
interface continua usando o atlas estatico local. Tiles ausentes ou corrompidos
sao ignorados individualmente, sem quebrar o mapa base.

## Projecao

O atlas legado usa Leaflet `CRS.Simple` com:

```js
new L.Transformation(0.02072, 117.3, -0.0205, 172.8)
```

Esses valores estao em `Config.Map.tiles.projection` e em
`web/js/projection.js` (`tilePixel` / `tileWorldRect`). Eles **nao** sao um CRS
oficial do GTA V e exigem calibracao visual com landmarks reais antes de uso em
producao.

## Licenca

O atlas local foi derivado do asset de referencia ja presente no repositorio e
associado ao projeto publico `RiceaRaul/gta-v-map-leaflet`, que declara MIT. A
arte cartografica de GTA V permanece propriedade da Rockstar Games; consulte o
`atlas.json` antes de redistribuir o resource fora do contexto autorizado do
servidor. O asset foi reduzido e colorizado localmente, sem alteracao geografica.
