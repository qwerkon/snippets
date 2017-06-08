function polishFlexiveNameEndings($firstName)
{
    $str = "";
    $matchesTmp = [];

    $parts = explode(' ', $firstName);
    if (count($parts) > 1) {
        foreach ($parts AS $iK => $firstName)
            $parts[$iK] = odmianaImion($firstName);

        return implode(' ', $parts);
    } else {
        if (!preg_match("/(e|i|o|u|y)$/iu", $firstName)) {
            if (preg_match("/(.*)a$/iu", $firstName, $matchesTmp)) {
                if (preg_match("/(ia)$/iu", $firstName, $matches)) {
                    preg_match("/(.*)ia$/iu", $firstName, $matches);
                    $sign = end(str_split($matches[1]));

                    switch ($sign) {
                        case 'r':
                        case 'n':
                            $str = "o";
                            break;
                        default:
                            $str = "no";
                            break;
                    }
                } elseif (preg_match("/(n{1,2}a)$/iu", $firstName, $matches) ||
                    preg_match("/(ja)$/iu", $firstName, $matches)
                ) {
                    $str = "o";
                    $matchesTmp[1] = preg_replace('#(n){2,}#iu', 'n', $matchesTmp[1]);
                } elseif (preg_match("/(l{1,2}a)$/iu", $firstName, $matches)) {
                    $str = "u";
                    if (preg_match("/(l{2}a)$/iu", $firstName, $matches))
                        $str = "o";

                    $matchesTmp[1] = preg_replace('#(l){2,}#iu', 'l', $matchesTmp[1]);
                } elseif (preg_match("/(([^c]i)|([^ansz])a)$/iu", $firstName, $matches)) {
                    $str = "o";
                }
            } elseif (preg_match("/(c|g|k)$/iu", $firstName) &&
                preg_match("/(.*?)([clnsz]ie|)(e|)(c|g|k)$/iu", $firstName, $matchesTmp)
            ) {
                if (!empty($matchesTmp[2])) {
                    switch ($matchesTmp[2]) {
                        case "cie":
                            $str = "ć";
                            break;
                        case "lie":
                            $str = "ł";
                            break;
                        case "nie":
                            $str = "ń";
                            break;
                        case "sie":
                            $str = "ś";
                            break;
                        case "zie":
                            $str = "ź";
                            break;
                        default:
                            $str = "u";
                            break;
                    }
                } elseif ($matchesTmp[3] == 'e') // np. 'Franciszek'
                {
                    $str = "ku";
                }
            } elseif (preg_match("/(h|j|l|sz|cz|rz|ż|Ż)$/iu", $firstName) &&
                preg_match("/(.*)/iu", $firstName, $matchesTmp)
            ) {
                $str = "u";
            } elseif (preg_match("/(b|f|m|n|p|s|v|w|[^src]z)$/iu", $firstName) &&
                preg_match("/(.*)/iu", $firstName, $matchesTmp)
            ) {
                $str = "ie";
            } elseif (preg_match("/(t)$/iu", $firstName) &&
                preg_match("/(.*)t/iu", $firstName, $matchesTmp)
            ) {
                $str = "cie";
            } elseif (preg_match("/(d)$/iu", $firstName) &&
                preg_match("/(.*)/iu", $firstName, $matchesTmp)
            ) {
                $str = "zie";
            } elseif (preg_match("/(ł)$/iu", $firstName) &&
                preg_match("/(.*?)(e|)(ł)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "le";
            } elseif (preg_match("/(ń)$/iu", $firstName) &&
                preg_match("/(.*)(ń)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "cie";
            } elseif (preg_match("/(ź)$/iu", $firstName) &&
                preg_match("/(.*)(ź)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "cie";
            } elseif (preg_match("/(ś)$/iu", $firstName) &&
                preg_match("/(.*)(ś)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "cie";
            } elseif (preg_match("/(x)$/iu", $firstName) &&
                preg_match("/(.*)(x)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "ksie";
            } elseif (preg_match("/(r)$/iu", $firstName) &&
                preg_match("/(.*?)(e|)(r)$/iu", $firstName, $matchesTmp)
            ) {
                $str = "rze";
            }
        } elseif (preg_match("/(e|i|o|u|y)$/iu", $firstName) &&
            preg_match("/(.*)(e|i|o|u|y)$/iu", $firstName, $matchesTmp)
        ) {
            $str = $matchesTmp[2];
        }

        return $matchesTmp[1] . $str;
    }
}
