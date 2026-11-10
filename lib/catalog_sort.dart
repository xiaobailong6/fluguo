import 'package:lpinyin/lpinyin.dart';

/// 搜索归一化会去掉标点与空白，弹幕屏蔽词、标题过滤都要逐条走一遍。
/// 正则预编译成顶层常量，避免每次调用都重新编译一次。
final _searchNoise = RegExp(
  r'[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]+',
);

/// 「第N季 / 第N部」的中文数字折叠，同样只编译一次。
final _seasonOrder = RegExp(r'第([0-9零〇一二两兩三四五六七八九十百]+)([季部])');

/// 自然排序把文本切成数字段与非数字段；排序比较每对元素都会用到。
final _naturalChunks = RegExp(r'\d+|\D+');

String normalizedSearchText(String text) {
  final value = String.fromCharCodes(
    text.runes.map(
      (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
    ),
  );
  return value.toLowerCase().replaceAll(_searchNoise, '');
}

bool matchesTitle(String title, String query) {
  final term = normalizedSearchText(query);
  if (term.isEmpty) return true;
  final text = normalizedSearchText(title);
  if (text.contains(term)) return true;
  try {
    return PinyinHelper.getShortPinyin(text).toLowerCase().contains(term);
  } on PinyinException {
    return false;
  }
}

int _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) return numeric;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  var digit = 0;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    if (digits.containsKey(character)) {
      digit = digit * 10 + digits[character]!;
    } else {
      final multiplier = character == '百' ? 100 : 10;
      number += (digit == 0 ? 1 : digit) * multiplier;
      digit = 0;
    }
  }
  return number + digit;
}

String _naturalTitle(String title) => normalizedSearchText(title)
    .replaceAllMapped(
      _seasonOrder,
      (match) => '第${_seasonNumber(match[1]!)}${match[2]}',
    );

/// 自然序比较键：`第N季` 之类的中文数字先折叠成阿拉伯数字。
///
/// 给一批标题排序时应先各自算一次键再比较，不要让比较器反复做归一化与正则
/// 折叠（原来每次比较都要把两边各重算一遍）。
String naturalTitleKey(String title) => _naturalTitle(title);

/// 比较两个 [naturalTitleKey] 的结果。
int naturalTitleKeyCompare(String left, String right) {
  final a = _naturalChunks.allMatches(left).map((match) => match[0]!).toList();
  final b = _naturalChunks.allMatches(right).map((match) => match[0]!).toList();
  for (var index = 0; index < a.length && index < b.length; index++) {
    final numberA = int.tryParse(a[index]);
    final numberB = int.tryParse(b[index]);
    final comparison = numberA != null && numberB != null
        ? numberA.compareTo(numberB)
        : a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return a.length.compareTo(b.length);
}

int naturalTitleCompare(String left, String right) =>
    naturalTitleKeyCompare(_naturalTitle(left), _naturalTitle(right));
