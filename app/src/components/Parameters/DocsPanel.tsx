import { OpenInNew } from "@mui/icons-material";
import {
  Box,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Typography,
} from "@mui/material";
import { TIDARR_REPO_URL } from "src/contants";

import { ModuleTitle } from "../TidalModule/Title";

interface DocLink {
  title: string;
  description: string;
  url: string;
}

const docLinks: DocLink[] = [
  {
    title: "Tidarr for Windows",
    description: "Getting started, launcher and folder layout",
    url: `https://github.com/${TIDARR_REPO_URL}#readme`,
  },
  {
    title: "Tiddl Configuration",
    description: "Quality settings, threads, and download options",
    url: "https://github.com/oskvr37/tiddl/blob/main/docs/config.example.toml",
  },
  {
    title: "Path Templating",
    description: "Customize folder structure and file naming",
    url: "https://github.com/oskvr37/tiddl/blob/main/docs/templating.md",
  },
  {
    title: "Tidal Authentication",
    description: "Login and token handling with tiddl",
    url: "https://github.com/oskvr37/tiddl#authentication",
  },
  {
    title: "Report an issue",
    description: "Bugs and feature requests for this Windows build",
    url: `https://github.com/${TIDARR_REPO_URL}/issues`,
  },
];

export default function DocsPanel() {
  return (
    <Box>
      <ModuleTitle title="Documentation resources" />
      <List>
        {docLinks.map((doc) => (
          <ListItemButton
            key={doc.url}
            component="a"
            href={doc.url}
            target="_blank"
            rel="noopener noreferrer"
            sx={{
              border: 1,
              borderColor: "divider",
              borderRadius: 1,
              mb: 1,
            }}
          >
            <ListItemText
              primary={<Typography color="primary">{doc.title}</Typography>}
              secondary={doc.description}
            />
            <ListItemIcon sx={{ minWidth: "auto" }}>
              <OpenInNew />
            </ListItemIcon>
          </ListItemButton>
        ))}
      </List>
    </Box>
  );
}
