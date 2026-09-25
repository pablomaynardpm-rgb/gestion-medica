// Regenera guia-premium/base.pdf desde cero a partir del texto de este
// archivo (en vez de editar el PDF binario a mano). Para modificar el
// contenido de la guía: cambiá los textos de las llamadas a heading() /
// paragraph() / bulletList() / stepBlock() / table() más abajo, después:
//   npm install
//   npm run build
const fs = require('fs');
const path = require('path');
const { PDFDocument, StandardFonts, rgb } = require('pdf-lib');

const LOGO_PATH = path.join(__dirname, '..', 'logo.png');
const OUT_PATH = path.join(__dirname, '..', 'base.pdf');

const W = 595.28, H = 841.89;
const MARGIN = 56;
const CONTENT_W = W - MARGIN * 2;
const HEADER_BOTTOM = H - 78;
const CONTENT_TOP = H - 100;
const FOOTER_Y = 34;

const navy = rgb(0x0E / 255, 0x4B / 255, 0x78 / 255);
const gray = rgb(0x50 / 255, 0x56 / 255, 0x5E / 255);
const lightGray = rgb(0x8A / 255, 0x92 / 255, 0x9B / 255);
const softBlue = rgb(0xCE / 255, 0xDE / 255, 0xEE / 255);
const softBlueBg = rgb(0xEA / 255, 0xF1 / 255, 0xF8 / 255);
const white = rgb(1, 1, 1);

async function main() {
  const logoBytes = fs.readFileSync(LOGO_PATH);
  const doc = await PDFDocument.create();
  const logoImg = await doc.embedPng(logoBytes);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  const body = await doc.embedFont(StandardFonts.Helvetica);
  const italic = await doc.embedFont(StandardFonts.HelveticaOblique);

  const logoDim = logoImg.scale(30 / logoImg.width);

  let page = null;
  let y = 0;
  let pageNum = 0;
  const pages = [];

  function wrapText(text, font, size, maxW) {
    const words = String(text).split(' ');
    const lines = [];
    let line = '';
    for (const w of words) {
      const test = line ? line + ' ' + w : w;
      if (font.widthOfTextAtSize(test, size) > maxW && line) { lines.push(line); line = w; }
      else line = test;
    }
    if (line) lines.push(line);
    return lines;
  }

  function newPage() {
    page = doc.addPage([W, H]);
    pageNum += 1;
    pages.push(page);
    // header
    page.drawImage(logoImg, { x: MARGIN, y: H - 34 - logoDim.height, width: logoDim.width, height: logoDim.height });
    page.drawText('DR. PABLO MAYNARD', { x: MARGIN + logoDim.width + 10, y: H - 34 - 9, size: 11, font: bold, color: navy });
    const nameW = bold.widthOfTextAtSize('DR. PABLO MAYNARD', 11);
    page.drawText('  Cirujano Torácico', { x: MARGIN + logoDim.width + 10 + nameW, y: H - 34 - 9, size: 10, font: italic, color: gray });
    page.drawLine({ start: { x: MARGIN, y: HEADER_BOTTOM }, end: { x: W - MARGIN, y: HEADER_BOTTOM }, thickness: 1, color: softBlue });
    y = CONTENT_TOP;
  }

  function checkSpace(h) {
    if (y - h < FOOTER_Y + 20) newPage();
  }

  function heading(text) {
    checkSpace(40);
    y -= 8;
    page.drawText(text, { x: MARGIN, y, size: 16, font: bold, color: navy });
    y -= 6;
    page.drawLine({ start: { x: MARGIN, y }, end: { x: W - MARGIN, y }, thickness: 1, color: softBlue });
    y -= 20;
  }

  function subheading(text) {
    checkSpace(26);
    page.drawText(text, { x: MARGIN, y, size: 12.5, font: bold, color: navy });
    y -= 18;
  }

  function paragraph(text, opts) {
    opts = opts || {};
    const size = opts.size || 11;
    const lineH = opts.lineH || 15;
    const font = opts.bold ? bold : body;
    const color = opts.color || gray;
    const lines = wrapText(text, font, size, CONTENT_W);
    lines.forEach((line) => {
      checkSpace(lineH);
      page.drawText(line, { x: MARGIN, y, size, font, color });
      y -= lineH;
    });
    y -= (opts.gapAfter != null ? opts.gapAfter : 10);
  }

  function bulletList(items) {
    const size = 11, lineH = 15, indent = 14;
    items.forEach((item) => {
      const lines = wrapText(item, body, size, CONTENT_W - indent);
      checkSpace(lineH);
      page.drawText('•', { x: MARGIN, y, size, font: body, color: navy });
      lines.forEach((line, i) => {
        if (i > 0) checkSpace(lineH);
        page.drawText(line, { x: MARGIN + indent, y, size, font: body, color: gray });
        y -= lineH;
      });
    });
    y -= 8;
  }

  function table(rows, colWidths) {
    const rowH = 24, size = 10;
    const totalW = colWidths.reduce((a, b) => a + b, 0);
    rows.forEach((row, ri) => {
      const lineCounts = row.map((cell, ci) => wrapText(cell, ri === 0 ? bold : body, size, colWidths[ci] - 16).length);
      const thisRowH = Math.max(rowH, Math.max(...lineCounts) * 13 + 12);
      checkSpace(thisRowH);
      const rowTop = y;
      const bg = ri === 0 ? navy : (ri % 2 === 0 ? softBlueBg : white);
      page.drawRectangle({ x: MARGIN, y: rowTop - thisRowH, width: totalW, height: thisRowH, color: bg, borderColor: softBlue, borderWidth: 0.75 });
      let cx = MARGIN;
      row.forEach((cell, ci) => {
        const cellFont = ri === 0 ? bold : body;
        const cellColor = ri === 0 ? white : gray;
        const lines = wrapText(cell, cellFont, size, colWidths[ci] - 16);
        let cy = rowTop - 15;
        lines.forEach((line) => {
          page.drawText(line, { x: cx + 8, y: cy, size, font: cellFont, color: cellColor });
          cy -= 13;
        });
        if (ci > 0) page.drawLine({ start: { x: cx, y: rowTop }, end: { x: cx, y: rowTop - thisRowH }, thickness: 0.75, color: softBlue });
        cx += colWidths[ci];
      });
      y = rowTop - thisRowH;
    });
    y -= 14;
  }

  function stepBlock(num, title, text) {
    const size = 11, lineH = 15, indent = 34;
    const lines = wrapText(text, body, size, CONTENT_W - indent);
    const blockH = 20 + lines.length * lineH + 10;
    checkSpace(blockH);
    const top = y;
    page.drawRectangle({ x: MARGIN, y: top - blockH, width: CONTENT_W, height: blockH, color: softBlueBg });
    page.drawText(String(num), { x: MARGIN + 10, y: top - 22, size: 13, font: bold, color: navy });
    page.drawText(title, { x: MARGIN + indent, y: top - 20, size: 12, font: bold, color: navy });
    let ly = top - 36;
    lines.forEach((line) => {
      page.drawText(line, { x: MARGIN + indent, y: ly, size, font: body, color: gray });
      ly -= lineH;
    });
    y = top - blockH - 10;
  }

  // ---- contenido ----
  newPage();

  heading('Antes de arrancar');
  paragraph('Armé esta guía para vos, para que tengas todo el proceso de tu cirugía ordenado en un solo lugar: qué vas a necesitar antes, qué va a pasar el día de la cirugía, qué vas a sentir al despertar, y cómo sigue todo una vez que estés en tu casa.');
  paragraph('Sé que una cirugía genera nervios, incluso cuando el riesgo es bajo — es así para casi todos mis pacientes, y es totalmente normal. Prefiero que tengas esto por escrito desde ahora, en vez de que te vayas enterando de cada paso sobre la marcha.');
  paragraph('Leela con calma, andá completando los espacios en blanco a medida que avanzás, y anotá cualquier duda que te surja en la última sección. Las repasamos juntos en la próxima consulta, o me escribís directo — para eso estoy.');
  y -= 2;
  paragraph('Pablo', { bold: true, gapAfter: 2, color: navy });
  paragraph('Dr. Pablo Maynard — Cirujano Torácico — M.N. 121828 / M.P. 232938', { size: 9.5, gapAfter: 2, color: lightGray });
  paragraph('cirugia.torax.maynard@gmail.com', { size: 9.5, gapAfter: 2, color: lightGray });
  paragraph('pablomaynard.com.ar · @dr.maynard.pablo', { size: 9.5, gapAfter: 22, color: lightGray });

  heading('Cronograma del proceso');
  paragraph('Cinco etapas, de principio a fin. Cada una la vas a encontrar detallada más adelante en esta guía.', { gapAfter: 14 });
  stepBlock(1, 'Preoperatorio', 'Estudios prequirúrgicos, evaluación con los distintos profesionales y firma del consentimiento informado.');
  stepBlock(2, 'Día de la cirugía', 'Ingreso a la institución, contacto conmigo antes de entrar a quirófano, procedimiento y recuperación inmediata.');
  stepBlock(3, 'Internación', 'Días de internación según el procedimiento, con control diario del equipo tratante.');
  stepBlock(4, 'Posoperatorio inmediato', 'Primeras 72 horas en casa: control de dolor, cuidados de la herida y línea directa de contacto.');
  stepBlock(5, 'Controles', 'Control en el consultorio dentro de los 10 días aproximadamente del alta, y otros controles si hacen falta — los vamos acordando juntos según cómo evoluciones. Resultado de anatomía patológica si corresponde.');

  heading('El día de la cirugía');
  subheading('Qué llevar');
  bulletList([
    'Tu DNI y el carnet de tu obra social o prepaga',
    'Todos los estudios prequirúrgicos ya completos',
    'El consentimiento informado firmado (si no lo firmaste antes en el consultorio)',
    'Tu medicación habitual, con la indicación de qué tomar y qué suspender que ya charlamos en la consulta',
    'Ropa cómoda para la internación; dejá los objetos de valor en tu casa',
    'El ayuno que te indiquemos (habitualmente 8 horas para sólidos)'
  ]);

  subheading('Antes de entrar a quirófano');
  paragraph('Te voy a llamar personalmente, por teléfono o videollamada, la noche anterior o esa misma mañana. Prefiero que lleguemos juntos a ese momento con la menor incertidumbre posible — cualquier cosa que te preocupe, la charlamos ahí.', { gapAfter: 16 });

  subheading('Al despertar');
  paragraph('Vas a despertar en el mismo quirófano, apenas termina la cirugía, ya sin la ayuda respiratoria que tuviste durante el procedimiento. Desde ahí te trasladamos para continuar el control en las primeras horas.');
  paragraph('Es normal sentir cosas distintas a lo que uno se imagina. Las más frecuentes:', { gapAfter: 6 });
  bulletList([
    'Garganta irritada o ronquera por el tubo que tuviste durante la cirugía — mejora en uno o dos días',
    'Un poco de desorientación o somnolencia los primeros minutos, hasta que termina de pasar el efecto de la anestesia',
    'Frío o temblores — es un efecto frecuente de la anestesia, no una señal de alarma',
    'Sed y sequedad en la boca',
    'Sensación de peso u opresión en el pecho, por el tubo de drenaje pleural que te queda colocado (en la gran mayoría de los casos alcanza con uno solo)'
  ]);
  paragraph('El dolor lo controlamos con analgesia programada, no a demanda. Avisame siempre si lo sentís por encima de lo esperado — no hay ningún motivo para aguantarlo.', { gapAfter: 18 });

  heading('Cuidados posoperatorios');
  subheading('Cuidados generales');
  bulletList([
    'Tomá la analgesia indicada de forma programada, no solo cuando el dolor ya te está molestando',
    'Hacé los ejercicios respiratorios que te indique kinesiología — son clave para una buena recuperación del pulmón',
    'Caminá y movete apenas te sientas en condiciones; cuanto antes te muevas, menos complicaciones',
    'Mantené la herida limpia y seca; no te pongas cremas ni apósitos que no te haya indicado'
  ]);

  subheading('Señales de alarma — consultá de inmediato');
  bulletList([
    'Fiebre mayor a 38°C',
    'Dificultad para respirar o sensación de falta de aire',
    'Dolor torácico intenso que no cede con la analgesia indicada',
    'Sangrado, secreción con mal olor o enrojecimiento progresivo en la herida',
    'Hinchazón, dolor o enrojecimiento en una pierna (posible señal de trombosis)'
  ]);
  paragraph('Ante cualquiera de estos signos, escribime directo por el WhatsApp de la sección de contactos, o andá a la guardia más cercana.', { gapAfter: 18 });

  heading('Contactos');
  table([
    ['Contacto', 'Datos'],
    ['WhatsApp — dudas posoperatorias (primeras 72 hs)', '+54 11 5104-2538'],
    ['Dr. Pablo Maynard — contacto pacientes', 'cirugia.torax.maynard@gmail.com'],
    ['Emergencias', 'Guardia de la institución / 911']
  ], [230, CONTENT_W - 230]);

  heading('Tus preguntas');
  paragraph('Anotá acá cualquier duda que te surja leyendo esta guía. Las charlamos juntos en la próxima consulta — ninguna pregunta es de más.', { gapAfter: 10 });

  // página final: solo marca de agua, como cierre
  newPage();
  const wmScale = 260 / logoImg.width;
  const wmDim = { width: 260, height: logoImg.height * wmScale };
  page.drawImage(logoImg, {
    x: (W - wmDim.width) / 2, y: (H - wmDim.height) / 2,
    width: wmDim.width, height: wmDim.height, opacity: 0.08
  });

  // pie de página en todas
  pages.forEach((pg, i) => {
    pg.drawText(`Página ${i + 1} de ${pages.length}`, {
      x: W / 2 - body.widthOfTextAtSize(`Página ${i + 1} de ${pages.length}`, 8.5) / 2,
      y: FOOTER_Y - 10, size: 8.5, font: body, color: lightGray
    });
  });

  const bytes = await doc.save();
  fs.writeFileSync(OUT_PATH, bytes);
  console.log('OK ->', OUT_PATH, bytes.length, 'bytes,', pages.length, 'páginas');
}

main().catch((e) => { console.error(e); process.exit(1); });
